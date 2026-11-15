require "test_helper"

class Balance::SyncCacheTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    ExchangeRate.stubs(:provider).returns(nil)
    @account = families(:empty).accounts.create!(name: "UAH cash", balance: 0, cash_balance: 0, currency: "UAH", accountable: Depository.new)
    @investment = families(:empty).accounts.create!(name: "UAH brokerage", balance: 0, cash_balance: 0, currency: "UAH", accountable: Investment.new)
    @security = Security.create!(ticker: "SYNC#{SecureRandom.hex(3)}", name: "Sync cache security")
  end

  test "indexes entries by date" do
    day = 3.days.ago.to_date
    valuation = create_valuation(account: @account, date: day, amount: 1_000, currency: "UAH")
    expense = create_transaction(account: @account, date: day, amount: 100, currency: "UAH")
    other_day = create_transaction(account: @account, date: day + 1.day, amount: 50, currency: "UAH")

    cache = Balance::SyncCache.new(@account)

    assert_equal valuation.id, cache.get_valuation(day).id
    assert_equal [ expense.id ], cache.get_entries(day).map(&:id)
    assert_equal [ other_day.id ], cache.get_entries(day + 1.day).map(&:id)
    assert_equal [], cache.get_entries(day + 2.days)
    assert_nil cache.get_valuation(day + 1.day)
  end

  test "converts a foreign entry at its own date" do
    day = 3.days.ago.to_date
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: day, rate: 41)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 45)
    create_transaction(account: @account, date: day, amount: 10, currency: "USD")

    entry = Balance::SyncCache.new(@account).get_entries(day).first

    assert_equal 410, entry.amount
    assert_equal "UAH", entry.currency
  end

  test "sums holdings value by date" do
    day = 2.days.ago.to_date
    other = Security.create!(ticker: "SYNC#{SecureRandom.hex(3)}", name: "Other")
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: day, rate: 40)
    @investment.holdings.create!(security: @security, date: day, qty: 1, price: 1_000, amount: 1_000, currency: "UAH")
    @investment.holdings.create!(security: other, date: day, qty: 1, price: 10, amount: 10, currency: "USD")
    @investment.holdings.create!(security: @security, date: day + 1.day, qty: 2, price: 1_000, amount: 2_000, currency: "UAH")

    cache = Balance::SyncCache.new(@investment)

    assert_equal 1_400, cache.get_holdings_value(day)
    assert_equal 2_000, cache.get_holdings_value(day + 1.day)
    assert_equal 0, cache.get_holdings_value(day + 2.days)
    assert_equal 0, cache.unconvertible_holding_count
  end

  test "an entry with no exchange rate is left out and counted" do
    day = 3.days.ago.to_date
    create_transaction(account: @account, date: day, amount: 100, currency: "UAH")
    create_transaction(account: @account, date: day, amount: 10, currency: "PLN")

    cache = Balance::SyncCache.new(@account)

    assert_equal [ 100 ], cache.get_entries(day).map(&:amount)
    assert_equal 1, cache.unconvertible_entry_count
  end

  test "a holding with no exchange rate keeps its 1:1 value and is counted" do
    day = 2.days.ago.to_date
    @investment.holdings.create!(security: @security, date: day, qty: 1, price: 10, amount: 10, currency: "PLN")

    cache = Balance::SyncCache.new(@investment)

    assert_equal 10, cache.get_holdings_value(day)
    assert_equal 1, cache.unconvertible_holding_count
  end

  test "writes one debug log entry per calculation with the counts and pairs" do
    day = 2.days.ago.to_date
    create_transaction(account: @investment, date: day, amount: 10, currency: "PLN")
    create_transaction(account: @investment, date: day - 1.day, amount: 20, currency: "PLN")
    @investment.holdings.create!(security: @security, date: day, qty: 1, price: 10, amount: 10, currency: "EUR")

    cache = Balance::SyncCache.new(@investment)
    cache.get_entries(day)
    cache.get_holdings_value(day)

    assert_difference -> { DebugLogEntry.where(source: "Balance::SyncCache").count }, 1 do
      cache.report_unconverted_amounts
    end

    entry = DebugLogEntry.where(source: "Balance::SyncCache").last
    assert_equal "warn", entry.level
    assert_equal @investment.id, entry.account_id
    assert_equal 2, entry.metadata["unconvertible_entry_count"]
    assert_equal 1, entry.metadata["unconvertible_holding_count"]
    assert_equal [ "EUR->UAH", "PLN->UAH" ], entry.metadata["missing_rate_pairs"]
  end

  test "writes no debug log entry when everything converts" do
    create_transaction(account: @account, date: 2.days.ago.to_date, amount: 10, currency: "UAH")
    cache = Balance::SyncCache.new(@account)
    cache.get_entries(2.days.ago.to_date)

    assert_no_difference -> { DebugLogEntry.count } do
      cache.report_unconverted_amounts
    end
  end

  test "a sync with an unconvertible entry still calculates the account and logs once" do
    create_valuation(account: @account, date: 5.days.ago.to_date, amount: 1_000, currency: "UAH", kind: "opening_anchor")
    create_transaction(account: @account, date: 3.days.ago.to_date, amount: 100, currency: "UAH")
    create_transaction(account: @account, date: 2.days.ago.to_date, amount: 10, currency: "PLN")

    assert_difference -> { DebugLogEntry.where(source: "Balance::SyncCache").count }, 1 do
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    assert_equal 900, @account.reload.balance
  end

  test "a future-dated entry does not change the balance of today" do
    create_valuation(account: @account, date: 5.days.ago.to_date, amount: 1_000, currency: "UAH", kind: "opening_anchor")
    create_transaction(account: @account, date: 1.day.from_now.to_date, amount: 300, currency: "UAH")

    balances = Balance::ForwardCalculator.new(@account).calculate
    today = balances.find { |b| b.date == Date.current }

    assert_equal 1_000, today.balance

    Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    assert_equal 1_000, @account.reload.balance
  end
end
