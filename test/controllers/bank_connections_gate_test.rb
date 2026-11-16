require "test_helper"

# Each bank connection provider is switched on by name (BANK_CONNECTIONS_ENABLED).
# Turning one on must not expose the others.
class BankConnectionsGateTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    # Settings > Sync Providers is a self-hosted page
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
  end

  test "with only one provider on, every other provider's pages are not found" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "lunchflow") do
      sign_in @user

      (plaid_paths + other_paths).each do |path|
        get path
        assert_response :not_found, "expected #{path} to be not found"
      end

      get new_lunchflow_item_path
      assert_not_equal 404, response.status

      get settings_providers_path
      assert_response :success
      get settings_bank_sync_path
      assert_response :success
    end
  end

  test "webhooks follow the plaid switch" do
    PlaidItem::WebhookProcessor.expects(:new).never

    { "lunchflow" => :not_found, "junk" => :not_found, "" => :not_found }.each do |value, expected|
      with_env_overrides("BANK_CONNECTIONS_ENABLED" => value) do
        post webhooks_plaid_path, params: { webhook_type: "TRANSACTIONS" }, as: :json
        assert_response expected, "BANK_CONNECTIONS_ENABLED=#{value.inspect}"
      end
    end

    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "plaid,lunchflow") do
      post webhooks_plaid_path, params: { webhook_type: "TRANSACTIONS" }, as: :json
      # Reached: the (unsigned) request is rejected by the verification, not hidden
      assert_response :bad_request
    end
  end

  test "junk in the switch turns every provider page off" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "junk") do
      sign_in @user

      (plaid_paths + other_paths + [ new_lunchflow_item_path, settings_providers_path, settings_bank_sync_path ]).each do |path|
        get path
        assert_response :not_found, "expected #{path} to be not found"
      end
    end
  end

  test "true turns every provider on" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "true") do
      sign_in @user

      [ new_lunchflow_item_path, new_coinstats_item_path, select_existing_account_plaid_items_path(account_id: accounts(:depository).id) ].each do |path|
        get path
        assert_not_equal 404, response.status, path
      end
    end
  end

  test "sync providers page shows only the enabled providers' settings and panels" do
    enable_bank_connections(:lunchflow)
    sign_in @user

    get settings_providers_path

    assert_response :success
    assert_select "turbo-frame#lunchflow-providers-panel"
    assert_select "turbo-frame#enable_banking-providers-panel", count: 0
    assert_select "turbo-frame#coinstats-providers-panel", count: 0
    assert_select "turbo-frame#coinbase-providers-panel", count: 0
    assert_select "input[name=?]", "setting[plaid_client_id]", count: 0
  end

  test "sync providers page shows plaid settings when plaid is on" do
    enable_bank_connections(:plaid)
    sign_in @user

    get settings_providers_path

    assert_response :success
    assert_select "input[name=?]", "setting[plaid_client_id]"
    assert_select "turbo-frame#lunchflow-providers-panel", count: 0
  end

  test "settings of a provider that is off can't be changed" do
    enable_bank_connections(:lunchflow)
    sign_in @user
    patch settings_providers_path, params: { setting: { plaid_client_id: "changed" } }

    assert_redirected_to settings_providers_path
    assert_not_equal "changed", Setting[:plaid_client_id]
  end

  test "bank sync lists only the enabled providers" do
    enable_bank_connections(:enable_banking)
    sign_in @user

    get settings_bank_sync_path

    assert_response :success
    assert_select "p", text: "Enable Banking (beta)"
    assert_select "p", text: "Plaid", count: 0
    assert_select "p", text: "Lunch Flow", count: 0
  end

  test "bank sync opens monobank's connect panel in the app, not the bank's website" do
    enable_bank_connections(:monobank)
    sign_in @user

    get settings_bank_sync_path

    assert_select "a[href=?]:not([target])", settings_providers_path(open: "monobank"), text: /monobank/
    assert_select "a[href^='https://api.monobank.ua']", count: 0

    with_self_hosting do
      get settings_providers_path(open: "monobank")
      assert_response :success
      assert_select "details[open] turbo-frame#monobank-providers-panel"
    end
  end

  test "linking an account with no bank connected yet leads to Bank Sync" do
    enable_bank_connections(:monobank)
    @user.family.monobank_items.destroy_all
    sign_in @user
    account = @user.family.accounts.create!(name: "Mono Visa", balance: 0, currency: "UAH", accountable: CreditCard.new)

    get select_provider_account_path(account)

    assert_redirected_to settings_bank_sync_path
    assert_equal I18n.t("accounts.select_provider.connect_first"), flash[:alert]
  end

  test "accounts page lists a plaid-linked account with the manual ones while plaid is off" do
    enable_bank_connections(:lunchflow)
    sign_in @user

    get accounts_path

    assert_response :success
    assert_select "#manual-accounts", text: /#{accounts(:connected).name}/
    assert_select "#" + ActionView::RecordIdentifier.dom_id(plaid_items(:one)), count: 0
    assert_select "#" + ActionView::RecordIdentifier.dom_id(lunchflow_items(:one))
  end

  test "accounts page renders generic-listing provider items with their own partial" do
    generic = BankConnections.provider(:lunchflow).with(generic_listing: true)
    BankConnections.stubs(:enabled_providers).returns([ generic ])
    BankConnections.stubs(:enabled_keys).returns(Set.new)
    sign_in @user

    get accounts_path

    assert_response :success
    assert_select "#" + ActionView::RecordIdentifier.dom_id(lunchflow_items(:one)), count: 1
  end

  test "syncing an account of a provider that is off syncs the account itself" do
    enable_bank_connections(:lunchflow)
    sign_in @user
    PlaidItem.any_instance.expects(:sync_later).never

    assert_enqueued_jobs 1, only: SyncJob do
      post sync_account_path(accounts(:connected))
    end
  end

  test "new account offers only the enabled providers' connections" do
    Family.any_instance.stubs(:can_connect_lunchflow?).returns(true)
    enable_bank_connections(:plaid)
    sign_in @user

    get new_depository_path(step: "method_select")
    assert_response :success
    assert_select "a[href*=?]", "lunchflow_items", count: 0

    enable_bank_connections(:lunchflow)
    get new_depository_path(step: "method_select")
    assert_select "a[href*=?]", "lunchflow_items"
    assert_select "a[href*=?]", "plaid_items", count: 0
  end

  test "the link button shows only when an enabled provider can link the account type" do
    sign_in @user
    get accounts_path
    assert_select "a[href=?]", select_provider_account_path(accounts(:depository)), count: 0

    Family.any_instance.stubs(:can_connect_lunchflow?).returns(true)
    enable_bank_connections(:lunchflow)
    get accounts_path
    assert_select "a[href=?]", select_provider_account_path(accounts(:depository))
  end

  test "settings nav shows bank sync while any provider is on" do
    enable_bank_connections(:coinbase)
    sign_in @user

    get settings_profile_path

    assert_select "a[href=?]", settings_bank_sync_path
  end

  private
    def plaid_paths
      [ new_plaid_item_path ]
    end

    def other_paths
      [ new_enable_banking_item_path, coinstats_items_path, coinbase_items_path ]
    end
end
