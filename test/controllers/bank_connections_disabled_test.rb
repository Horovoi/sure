require "test_helper"

# With BANK_CONNECTIONS_ENABLED unset (the default), the bank and crypto
# connection providers are hidden and can't be reached by URL.
class BankConnectionsDisabledTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "provider pages are not found for a signed-in user" do
    sign_in @user

    [
      new_plaid_item_path,
      select_existing_account_plaid_items_path(account_id: accounts(:depository).id),
      lunchflow_items_path,
      new_lunchflow_item_path,
      new_enable_banking_item_path,
      callback_enable_banking_items_path,
      coinstats_items_path,
      new_coinstats_item_path,
      coinbase_items_path,
      new_coinbase_item_path,
      settings_providers_path,
      settings_bank_sync_path
    ].each do |path|
      get path
      assert_response :not_found, "expected #{path} to be not found"
    end
  end

  test "provider writes are not found and leave existing items untouched" do
    sign_in @user
    plaid_item = plaid_items(:one)

    assert_no_difference -> { PlaidItem.count } do
      post plaid_items_path, params: { plaid_item: { public_token: "public-sandbox-token", metadata: { institution: { name: "Bank" } } } }
      assert_response :not_found

      delete plaid_item_path(plaid_item)
      assert_response :not_found

      post sync_plaid_item_path(plaid_item)
      assert_response :not_found
    end

    assert_no_difference -> { CoinstatsItem.count } do
      post coinstats_items_path, params: { coinstats_item: { name: "Wallets", api_key: "key" } }
      assert_response :not_found
    end

    patch settings_providers_path, params: { setting: { plaid_client_id: "changed" } }
    assert_response :not_found
    assert_not_equal "changed", Setting[:plaid_client_id]

    assert_not plaid_item.reload.scheduled_for_deletion?
  end

  test "provider pages are not found for a signed-out visitor" do
    get new_plaid_item_path
    assert_response :not_found

    get callback_enable_banking_items_path, params: { code: "abc", state: "xyz" }
    assert_response :not_found
  end

  test "plaid webhooks are not found" do
    PlaidItem::WebhookProcessor.expects(:new).never

    post webhooks_plaid_path, params: { webhook_type: "TRANSACTIONS" }, as: :json
    assert_response :not_found

    post webhooks_plaid_eu_path, params: { webhook_type: "TRANSACTIONS" }, as: :json
    assert_response :not_found
  end

  test "settings nav hides bank sync" do
    sign_in @user

    get settings_profile_path

    assert_response :success
    assert_select "a[href=?]", settings_bank_sync_path, count: 0
  end

  test "settings nav shows bank sync when bank connections are enabled" do
    enable_bank_connections
    sign_in @user

    get settings_profile_path
    assert_select "a[href=?]", settings_bank_sync_path

    get settings_bank_sync_path
    assert_response :success
  end

  test "new depository form offers no provider link" do
    sign_in @user

    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href*=?]", "plaid_items", count: 0
    assert_select "a", text: /Link with/, count: 0
  end

  test "new depository form offers plaid when bank connections are enabled" do
    enable_bank_connections
    sign_in @user

    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href*=?]", "plaid_items"
    assert_select "a", text: /Link with/
  end
end
