require "test_helper"

class MonobankItemsControllerTest < ActionDispatch::IntegrationTest
  include MonobankTestHelper

  setup do
    enable_bank_connections(:monobank)
    setup_monobank_family
    sign_in users(:family_admin)
    @card = create_monobank_product(account_id: "uah-card", balance: 4_200_000, credit_limit: 5_000_000)
    @usd = create_monobank_product(account_id: "usd-card", currency: "USD", balance: 12_345)
    @jar = create_monobank_product(account_id: "jar-1", kind: "jar", title: "Відпустка", balance: 150_000)
    @visa = create_sure_account(name: "Mono Visa", accountable_type: "CreditCard")
    add_manual_transaction(@visa, date: Date.new(2026, 11, 13), amount: 100)
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
  end

  teardown { travel_back }

  test "404 while monobank is off, also when another provider is on" do
    enable_bank_connections(:plaid)

    get setup_accounts_monobank_item_url(@item)
    assert_response :not_found

    post monobank_items_url, params: { monobank_item: { access_token: "x" } }
    assert_response :not_found
  end

  test "creates a connection, queues its sync and never echoes the token" do
    assert_difference -> { @family.monobank_items.count }, 1 do
      post monobank_items_url, params: { monobank_item: { name: "", access_token: "secret-token-123", sync_start_date: "2026-01-01" } },
                               headers: { "Turbo-Frame" => "monobank-providers-panel" }
    end

    assert_response :success
    assert_not_includes response.body, "secret-token-123"
    item = @family.monobank_items.order(:created_at).last
    assert_equal [ "monobank", "secret-token-123", Date.new(2026, 1, 1) ], [ item.name, item.access_token, item.sync_start_date ]
    assert item.syncs.any?
  end

  test "a connection without a token is refused" do
    assert_no_difference -> { MonobankItem.count } do
      post monobank_items_url, params: { monobank_item: { name: "x", access_token: "" } }
    end
    assert_redirected_to settings_providers_url
  end

  test "update keeps the token when the field is empty and resets a refused connection on a new one" do
    @item.update!(status: :requires_update)

    patch monobank_item_url(@item), params: { monobank_item: { name: "Mine", access_token: "", include_pending: "0", apply_mcc_categories: "0" } }
    @item.reload
    assert_equal [ "Mine", "test_monobank_token", false, false ], [ @item.name, @item.access_token, @item.include_pending, @item.apply_mcc_categories ]
    assert @item.requires_update?

    patch monobank_item_url(@item), params: { monobank_item: { access_token: "new-token" } }
    assert_equal [ "new-token", true ], [ @item.reload.access_token, @item.good? ]
  end

  test "only admins change connections; members may sync" do
    sign_in users(:family_member)

    patch monobank_item_url(@item), params: { monobank_item: { name: "Hacked" } }
    assert_redirected_to settings_profile_url
    assert_equal "monobank", @item.reload.name

    post sync_monobank_item_url(@item)
    assert_response :redirect
    assert @item.syncs.any?
    assert @item.reload.force_forward_until.future?
  end

  test "another family's connection is not found" do
    other = MonobankItem.create!(family: families(:empty), name: "x", access_token: "t")

    patch monobank_item_url(other), params: { monobank_item: { name: "mine now" } }
    assert_response :not_found
  end

  test "setup preselects Mono Visa for the UAH credit card with its cut-over" do
    get setup_accounts_monobank_item_url(@item)

    assert_response :success
    assert_select "select[name='setup[#{@card.id}][choice]'] option[selected][value='link:#{@visa.id}']"
    assert_select "input[name='setup[#{@card.id}][cutover_date]'][value='2026-11-14']"
    assert_select "select[name='setup[#{@usd.id}][choice]'] option[selected][value='create:Depository:checking']"
    assert_select "select[name='setup[#{@jar.id}][choice]'] option[selected][value='create:Depository:savings']"
    assert_select "select[name='setup[#{@usd.id}][choice]'] option[value='link:#{@visa.id}']", count: 0
  end

  test "complete setup links Mono Visa, creates the rest and remembers a skip" do
    post complete_account_setup_monobank_item_url(@item), params: { setup: {
      @card.id => { choice: "link:#{@visa.id}", cutover_date: "2026-11-14" },
      @usd.id => { choice: "create:Depository:checking", cutover_date: "" },
      @jar.id => { choice: "skip" }
    } }

    assert_redirected_to accounts_url
    assert_equal @visa, @card.reload.current_account
    assert_equal Date.new(2026, 11, 14), @visa.reload.provider_cutover_date
    usd_account = @usd.reload.current_account
    assert_equal [ "USD", "Depository" ], [ usd_account.currency, usd_account.accountable_type ]
    assert @jar.reload.ignored?
    assert_not @item.reload.pending_account_setup?
    assert_match "1 created, 1 linked, 1 skipped", flash[:notice]
  end

  test "complete setup with an empty cut-over uses the default and reports a bad one" do
    post complete_account_setup_monobank_item_url(@item), params: { setup: { @card.id => { choice: "link:#{@visa.id}", cutover_date: "2026-12-01" } } }
    assert_match "in the future", flash[:alert]
    assert_nil @card.reload.current_account

    post complete_account_setup_monobank_item_url(@item), params: { setup: { @card.id => { choice: "link:#{@visa.id}", cutover_date: "" } } }
    assert_equal Date.new(2026, 11, 14), @visa.reload.provider_cutover_date
  end

  test "an account of another currency or family cannot be linked" do
    stranger = create_sure_account(name: "Elsewhere", family: families(:empty))

    post complete_account_setup_monobank_item_url(@item), params: { setup: { @card.id => { choice: "link:#{stranger.id}" } } }

    assert flash[:alert].present?
    assert_nil @card.reload.current_account
  end

  test "link an existing account from its page" do
    get select_existing_account_monobank_items_url(account_id: @visa.id, monobank_item_id: @item.id)
    assert_response :success
    assert_select "input[type=radio][value='#{@card.id}']"
    assert_select "input[type=radio][value='#{@usd.id}']", count: 0
    assert_select "input[name='link[cutover_date]'][value='2026-11-14']"

    post link_existing_account_monobank_items_url, params: { link: { monobank_item_id: @item.id, account_id: @visa.id, monobank_account_id: @card.id, cutover_date: "2026-11-10" } }

    assert_redirected_to account_url(@visa)
    assert_equal Date.new(2026, 11, 10), @visa.reload.provider_cutover_date
  end

  test "add products as new accounts from New account" do
    get select_accounts_monobank_items_url(monobank_item_id: @item.id, accountable_type: "Depository", return_to: "/accounts")
    assert_response :success
    assert_select "input[name='monobank_account_ids[]']", count: 3

    post link_accounts_monobank_items_url, params: { monobank_item_id: @item.id, accountable_type: "Depository",
                                                     monobank_account_ids: [ @usd.id, @jar.id ], return_to: "/accounts" }

    assert_redirected_to "/accounts"
    assert_equal %w[Depository Depository], [ @usd, @jar ].map { |product| product.reload.current_account.accountable_type }
  end

  test "disconnect unlinks the accounts and schedules deletion" do
    account = @item.create_linked_account!(monobank_account: @usd)

    delete monobank_item_url(@item)

    assert_redirected_to settings_providers_url
    assert @item.reload.scheduled_for_deletion?
    assert_not account.reload.linked?
  end

  test "the settings panel shows status, products and both forms" do
    @item.create_linked_account!(monobank_account: @usd)

    patch monobank_item_url(@item), params: { monobank_item: { name: "monobank" } }, headers: { "Turbo-Frame" => "monobank-providers-panel" }

    assert_response :success
    assert_includes response.body, "Black card ·1234 · USD"
    assert_includes response.body, "Linked to"
    assert_includes response.body, "statement pages left"
    assert_not_includes response.body, "test_monobank_token"
  end

  test "the accounts page card lists linked accounts and asks for setup" do
    linked = @item.create_linked_account!(monobank_account: @usd)
    Current.session = users(:family_admin).sessions.create!

    html = ApplicationController.render(partial: "monobank_items/monobank_item", locals: { monobank_item: @item.reload })

    assert_includes html, linked.name
    assert_includes html, "Accounts to set up"
    assert_includes html, setup_accounts_monobank_item_path(@item)
  ensure
    Current.reset
  end

  test "the accounts page and Settings > Sync Providers show monobank" do
    @item.create_linked_account!(monobank_account: @usd)

    get accounts_url
    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"

    with_self_hosting do
      get settings_providers_url
      assert_response :success
      assert_select "#monobank-providers-panel form[action='#{monobank_items_path}']"
    end
  end

  test "the connection dialog renders" do
    get new_monobank_item_url
    assert_response :success
  end
end
