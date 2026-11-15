require "test_helper"

class ProviderConnectionsHelperTest < ActionView::TestCase
  include ApplicationHelper
  include ProviderConnectionsHelper

  setup do
    @family = families(:dylan_family)
    Current.stubs(:family).returns(@family)
    @item = lunchflow_items(:one)
  end

  test "cutover text for an account taken over at a cutover date" do
    account = accounts(:credit_card)
    assert_nil provider_cutover_text(account)

    Account::ProviderLink.link!(account: account, provider_account: @item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"),
      cutover_date: Date.new(2026, 11, 14))

    text = provider_cutover_text(account.reload)
    assert_match(/come from Lunch Flow\. Earlier history is kept as you entered it\./, text)
    assert_includes text, format_date(Date.new(2026, 11, 14))
  end

  test "no cutover text for an account linked from the start" do
    account = accounts(:credit_card)
    Account::ProviderLink.link!(account: account, provider_account: @item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"), cutover_date: nil)

    assert_nil provider_cutover_text(account.reload)
  end

  test "item status in order of precedence" do
    item = stub(scheduled_for_deletion?: false, requires_update?: false, syncing?: false, sync_error: nil, last_synced_at: nil)
    assert_equal :never, provider_item_status(item).state

    item.stubs(:last_synced_at).returns(5.minutes.ago)
    assert_equal :ok, provider_item_status(item).state
    assert_match(/Synced 5 minutes ago/, provider_item_status(item).text)

    item.stubs(:sync_error).returns("Timeout")
    assert_equal :error, provider_item_status(item).state

    item.stubs(:backfill_progress).returns({ windows_remaining: 3, eta_seconds: 150, chain_active: true })
    status = provider_item_status(item)
    assert_equal :fetching, status.state
    assert_equal "Fetching history: 3 statement pages left (about 3 min)", status.text

    item.stubs(:syncing?).returns(true)
    assert_equal :syncing, provider_item_status(item).state

    item.stubs(:requires_update?).returns(true)
    assert_equal :requires_update, provider_item_status(item).state

    item.stubs(:scheduled_for_deletion?).returns(true)
    assert_equal :deleting, provider_item_status(item).state
  end

  test "an inactive history fetch does not show as fetching" do
    item = stub(scheduled_for_deletion?: false, requires_update?: false, syncing?: false, sync_error: nil, last_synced_at: nil,
      backfill_progress: { windows_remaining: 0, eta_seconds: 0, chain_active: false })

    assert_equal :never, provider_item_status(item).state
  end

  test "provider link button follows the enabled providers" do
    account = accounts(:depository)
    assert_not provider_link_available?(account)

    @provider_link_available = nil
    Family.any_instance.stubs(:can_connect_lunchflow?).returns(true)
    enable_bank_connections(:lunchflow)
    assert provider_link_available?(account)
  end
end
