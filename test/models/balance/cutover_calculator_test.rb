require "test_helper"

# An account with hand-kept history that a provider takes over at a cutover date
# (Account::ProviderLink): forward before the cutover, reverse from the provider's
# balance from it on, drift shown once on the cutover day.
class Balance::CutoverCalculatorTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  COLUMNS = %i[date balance cash_balance start_cash_balance start_non_cash_balance cash_inflows cash_outflows
               non_cash_inflows non_cash_outflows cash_adjustments non_cash_adjustments net_market_flows flows_factor].freeze

  setup do
    travel_to Date.new(2026, 11, 15)
    enable_bank_connections(:lunchflow)
  end

  test "keeps the history before the cutover byte-identical and shows the drift once on the cutover day" do
    account = build_ex_manual_account(Depository)
    before = rows(Balance::ForwardCalculator.new(account).calculate)

    link_and_import(account, provider_balance: 1_000 - 50 + 7)

    assert_equal :cutover, account.reload.balance_strategy
    calculated = Balance::CutoverCalculator.new(account).calculate
    cutover = account.provider_cutover_date
    assert_equal 12.days.ago.to_date, cutover

    before_cutover = rows(calculated).select { |row| row[:date] < cutover }
    assert_equal before.select { |row| row[:date] < cutover }, before_cutover

    forward_end = before.find { |row| row[:date] == cutover - 1.day }
    cutover_day = calculated.find { |row| row.date == cutover }
    assert_equal forward_end[:cash_balance], cutover_day.start_cash_balance
    # Reverse start of the cutover day: 957 + 30 + 20 = 1007; forward end: 1000
    assert_equal 7, cutover_day.cash_adjustments
    assert_equal 1_007, cutover_day.balance

    today = calculated.find { |row| row.date == Date.current }
    assert_equal 957, today.balance
    assert_equal calculated.map(&:date).uniq.size, calculated.size
    assert_equal (account.opening_anchor_date..Date.current).to_a, calculated.map(&:date)
  end

  test "credit card drift keeps the liability sign" do
    account = build_ex_manual_account(CreditCard)
    before = rows(Balance::ForwardCalculator.new(account).calculate)

    # Debt grows with each charge: reverse start of the cutover day = 1100 - 30 - 20 = 1050
    link_and_import(account, provider_balance: 1_100)

    calculated = Balance::CutoverCalculator.new(account.reload).calculate
    cutover = account.provider_cutover_date
    forward_end = before.find { |row| row[:date] == cutover - 1.day }
    cutover_day = calculated.find { |row| row.date == cutover }

    assert_equal(-1, cutover_day.flows_factor)
    assert_equal forward_end[:cash_balance], cutover_day.start_cash_balance
    assert_equal 1_050 - forward_end[:cash_balance], cutover_day.cash_adjustments
    assert_equal 1_050, cutover_day.balance
    assert_equal 1_100, calculated.find { |row| row.date == Date.current }.balance
  end

  test "counts pending holds when the provider balance includes them" do
    account = build_ex_manual_account(Depository)
    link_and_import(account, provider_balance: 950, pending: 15)

    Account.any_instance.stubs(:provider_balance_includes_pending?).returns(false)
    without = Balance::CutoverCalculator.new(account.reload).calculate
    Account.any_instance.stubs(:provider_balance_includes_pending?).returns(true)
    with = Balance::CutoverCalculator.new(account.reload).calculate

    cutover = account.provider_cutover_date
    assert_equal 1_000, without.find { |row| row.date == cutover }.balance
    assert_equal 1_015, with.find { |row| row.date == cutover }.balance
    assert_equal 950, with.find { |row| row.date == Date.current }.balance
  end

  test "the account sync persists cutover balances and keeps the provider balance" do
    account = build_ex_manual_account(Depository)
    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    stored_before = stored_rows(account)

    link_and_import(account, provider_balance: 957)
    Account::Syncer.new(account.reload).perform_sync(nil)

    cutover = account.provider_cutover_date
    assert_equal stored_before.select { |row| row["date"] < cutover }, stored_rows(account).select { |row| row["date"] < cutover }
    assert_equal 957, account.reload.balance
    assert_equal 957, account.balances.find_by(date: Date.current).end_balance
  end

  test "unlinking keeps today's balance and the history" do
    account = build_ex_manual_account(Depository)
    link_and_import(account, provider_balance: 957)
    Balance::Materializer.new(account.reload, strategy: :cutover).materialize_balances
    linked_history = account.balances.order(:date).pluck(:date, :end_balance)

    Account::ProviderLink.unlink!(account)
    account.reload
    assert account.manual?
    assert_equal :forward, account.balance_strategy
    assert_equal 0, account.valuations.current_anchor.count

    Account::Syncer.new(account).perform_sync(nil)

    assert_equal linked_history, account.balances.order(:date).pluck(:date, :end_balance)
    assert_equal 957, account.reload.balance
  end

  private
    # Opening 900 thirty days ago, then hand-entered transactions up to 13 days ago:
    # forward end on day -13 is 1000.
    def build_ex_manual_account(type)
      sign = type == CreditCard ? -1 : 1

      create_account_with_ledger(
        account: { type: type, balance: 1_000, cash_balance: 1_000, currency: "USD" },
        entries: [
          { type: "opening_anchor", date: 30.days.ago.to_date, balance: 900 },
          { type: "transaction", date: 25.days.ago.to_date, amount: -150 * sign },
          { type: "reconciliation", date: 20.days.ago.to_date, balance: 1_100 },
          { type: "transaction", date: 15.days.ago.to_date, amount: 60 * sign },
          { type: "transaction", date: 13.days.ago.to_date, amount: 40 * sign }
        ]
      )
    end

    def link_and_import(account, provider_balance:, pending: nil)
      item = LunchflowItem.create!(family: account.family, name: "Bank", api_key: "key")
      provider_account = item.lunchflow_accounts.create!(name: "Card", currency: "USD", account_id: "card-#{SecureRandom.hex(4)}")
      Account::ProviderLink.link!(account: account, provider_account: provider_account)

      adapter = Account::ProviderImportAdapter.new(account.reload)
      cutover = account.provider_cutover_date
      import = ->(id, date, amount, extra = nil) do
        adapter.import_transaction(external_id: id, amount: amount, currency: "USD", date: date, name: id,
          source: "lunchflow", cutover_date: cutover, extra: extra)
      end

      flip = account.accountable_type == "CreditCard" ? -1 : 1
      # The overlap row claims the hand-entered one, the older one is skipped
      import.call("overlap", 13.days.ago.to_date, 40 * flip)
      assert_nil import.call("old", 20.days.ago.to_date, 5)
      import.call("new-1", 5.days.ago.to_date, 30)
      import.call("new-2", Date.current, 20)
      import.call("hold", Date.current, pending, { "lunchflow" => { "pending" => true } }) if pending

      assert_equal 1, adapter.claimed_entries.size
      assert_equal [ "before_cutover" ], adapter.skipped_entries.map { |skip| skip[:reason] }

      assert adapter.update_balance(balance: provider_balance, source: "lunchflow").success?
    end

    def rows(calculated)
      calculated.sort_by(&:date).map { |balance| COLUMNS.index_with { |column| balance.public_send(column) } }
    end

    def stored_rows(account)
      account.balances.order(:date).map { |balance| balance.attributes.except("id", "created_at", "updated_at") }
    end
end
