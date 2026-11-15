require "test_helper"

class MonobankItem::FetchPlanTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
    @product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    @account = create_sure_account(name: "Black card")
    link_product(@product, @account)
  end

  teardown { travel_back }

  def plan(now: Time.current)
    MonobankItem::FetchPlan.new(@item.reload, now: now)
  end

  def store(window, rows = [])
    MonobankItem::Importer.new(@item, provider: nil).store_window!(window, rows)
  end

  test "first window: the last 31 days, kind first" do
    window = plan.next_window

    assert_equal :first, window.kind
    assert_equal @product, window.monobank_account
    assert_in_delta (Time.current - 31.days).to_f, window.from.to_f, 1
    assert_in_delta Time.current.to_f, window.to.to_f, 1
  end

  test "target start: a year ago by default, in the family zone" do
    target = MonobankItem::FetchPlan.target_start_for(@product)

    assert_equal (Time.current.in_time_zone("Europe/Kyiv") - 365.days).beginning_of_day, target
  end

  test "target start: MONOBANK_INITIAL_HISTORY_DAYS via the config" do
    Rails.configuration.x.monobank.stubs(:initial_history_days).returns(10)

    target = MonobankItem::FetchPlan.target_start_for(@product)
    assert_equal (Time.current.in_time_zone("Europe/Kyiv") - 10.days).beginning_of_day, target
    assert_in_delta target.to_f, plan.next_window.from.to_f, 1
  end

  test "target start: the product's then the connection's start date" do
    @item.update!(sync_start_date: Date.new(2026, 6, 1))
    assert_equal Time.find_zone("Europe/Kyiv").local(2026, 6, 1), MonobankItem::FetchPlan.target_start_for(@product.reload)

    @product.update!(sync_start_date: Date.new(2026, 9, 1))
    assert_equal Time.find_zone("Europe/Kyiv").local(2026, 9, 1), MonobankItem::FetchPlan.target_start_for(@product)
  end

  test "a cutover account starts 3 days before the cutover and needs one window" do
    Account::ProviderLink.unlink!(@account)
    add_manual_transaction(@account, date: Date.new(2026, 11, 13), amount: 50)
    link_product(@product, @account.reload, cutover_date: Date.new(2026, 11, 14))

    window = plan.next_window
    assert_equal :first, window.kind
    assert_equal Time.find_zone("Europe/Kyiv").local(2026, 11, 11), window.from

    store(window)
    @product.reload
    assert @product.history_complete?
    assert_nil plan.next_window
  end

  test "after the first window: backfill 31 days at a time down to the target" do
    first = plan.next_window
    store(first)

    backfill = plan.next_window
    assert_equal :backfill, backfill.kind
    assert_equal first.from.to_i, backfill.to.to_i
    assert_equal (first.from - 31.days).to_i, backfill.from.to_i

    windows = 1
    while (window = plan.next_window)
      store(window)
      windows += 1
      flunk "too many windows" if windows > 20
    end

    assert @product.reload.history_complete?
    assert_equal MonobankItem::FetchPlan.target_start_for(@product), @product.history_synced_from
    assert_equal 12, windows # 365 days
  end

  test "a full page of 500 rows is continued from its oldest row" do
    window = plan.next_window
    oldest = window.to - 10.days
    rows = 500.times.map { |i| monobank_row(id: "r#{i}", time: window.to - (i * 20).minutes, amount: -100) }
    rows[-1]["time"] = oldest.to_i

    assert_equal :partial, store(window, rows)

    page = plan.next_window
    assert_equal :first, page.kind
    assert_equal window.from.to_i, page.from.to_i
    assert_equal oldest.to_i, page.to.to_i
    assert_equal 500, @product.reload.page_seen_ids.size

    assert_equal :complete, store(page, [ monobank_row(id: "older", time: page.to - 1.day, amount: -5) ])
    @product.reload
    assert_nil @product.page_to
    assert_equal [], @product.page_seen_ids
    assert_equal 501, @product.raw_transactions_payload.size
    assert_equal window.from.to_i, @product.history_synced_from.to_i
    assert_in_delta window.to.to_f, @product.statement_synced_through.to_f, 1
  end

  test "a page whose oldest row is the previous page end moves one second earlier" do
    window = plan.next_window
    rows = 500.times.map { |i| monobank_row(id: "r#{i}", time: window.to - 1.hour, amount: -1) }
    store(window, rows)
    page = plan.next_window

    store(page, rows)
    assert_equal (page.to - 1.second).to_i, @product.reload.page_to.to_i
  end

  test "a gap after a long pause is walked forward 31 days at a time" do
    @product.update!(statement_synced_through: 80.days.ago, history_synced_from: 400.days.ago, history_complete: true,
                     forward_fetched_at: 80.days.ago, balance_at_forward_fetch: 100_00)

    window = plan.next_window
    assert_equal :gap, window.kind
    assert_equal (80.days.ago - 3.days).to_i, window.from.to_i
    assert_equal (window.from + 31.days).to_i, window.to.to_i
  end

  test "forward only when the balance changed, holds need a recheck, a day passed or Sync now asked" do
    @product.update!(statement_synced_through: 1.hour.ago, history_synced_from: 400.days.ago, history_complete: true,
                     forward_fetched_at: 1.hour.ago, balance_at_forward_fetch: 100_00)
    assert_nil plan.next_window, "balance unchanged: no request"

    @product.update!(raw_balance_minor: 90_00)
    window = plan.next_window
    assert_equal :forward, window.kind
    assert_equal (1.hour.ago - 3.days).to_i, window.from.to_i

    @product.update!(raw_balance_minor: 100_00, forward_fetched_at: 25.hours.ago)
    assert_equal :forward, plan.next_window.kind, "a day without a forward fetch"

    @product.update!(forward_fetched_at: 1.hour.ago)
    @item.force_forward!
    assert_equal :forward, plan.next_window.kind, "Sync now"
    @product.update!(forward_fetched_at: Time.current)
    assert_nil plan.next_window, "Sync now is served once"
  end

  test "an open hold is rechecked hourly and the window reaches back to it" do
    hold_time = 10.days.ago
    @product.update!(statement_synced_through: 10.minutes.ago, history_synced_from: 400.days.ago, history_complete: true,
                     forward_fetched_at: 10.minutes.ago, balance_at_forward_fetch: 100_00,
                     raw_transactions_payload: [ monobank_row(id: "hold", time: hold_time, amount: -500, hold: true) ])
    assert_nil plan.next_window, "fetched 10 minutes ago"

    window = plan(now: Time.current + 1.hour).next_window
    assert_equal :forward, window.kind
    assert_equal hold_time.to_i, window.from.to_i
  end

  test "skips ignored, unlinked, hidden and backed-off products" do
    other = create_monobank_product(account_id: "card-usd", currency: "USD")
    assert_equal [ @product ], plan.windows.map(&:monobank_account), "unlinked product"

    @product.update!(next_fetch_after: 10.minutes.from_now)
    assert_nil plan.next_window

    @product.update!(next_fetch_after: nil, ignored: true)
    assert_nil plan.next_window

    @product.update!(ignored: false)
    @account.update!(status: "disabled")
    assert_nil plan.next_window
    assert other
  end

  test "nothing for a connection that needs a new token or is being deleted" do
    @item.update!(status: :requires_update)
    assert_nil plan.next_window

    @item.update!(status: :good, scheduled_for_deletion: true)
    assert_nil plan.next_window
  end

  test "fresh data first: forward windows before backfill, gap before backfill" do
    @product.update!(statement_synced_through: Time.current, history_synced_from: 100.days.ago, history_complete: false,
                     forward_fetched_at: Time.current, balance_at_forward_fetch: 100_00)
    jar = create_monobank_product(account_id: "jar-1", kind: "jar", title: "Trip", balance: 5_00)
    link_product(jar, create_sure_account(name: "Trip"))

    assert_equal [ jar, :first ], [ plan.next_window.monobank_account, plan.next_window.kind ]
    store(plan.next_window)
    jar.update!(history_complete: true)

    assert_equal [ @product, :backfill ], [ plan.next_window.monobank_account, plan.next_window.kind ]
  end

  test "windows_remaining estimates the requests left" do
    assert_equal 12, plan.windows_remaining # first + 11 more 31-day windows to a year

    store(plan.next_window)
    assert_equal 11, plan.windows_remaining
  end
end
