require "test_helper"

class BalanceSheet::NetWorthBreakdownSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:empty)
  end

  test "monthly points whose groups add up to net worth" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 9, 15))

    cash = create_account(balance: 6_000, accountable: Depository.new)
    property = create_account(balance: 200_000, accountable: Property.new)
    card = create_account(balance: 1_500, accountable: CreditCard.new)
    loan = create_account(balance: 50_000, accountable: Loan.new)

    create_balance(account: cash, date: period.start_date, balance: 5_000)
    create_balance(account: cash, date: period.end_date, balance: 6_000)
    create_balance(account: property, date: period.start_date, balance: 200_000)
    create_balance(account: card, date: period.start_date, balance: 1_000)
    create_balance(account: card, date: period.end_date, balance: 1_500)
    create_balance(account: loan, date: Date.new(2026, 8, 1), balance: 50_000)

    series = builder.breakdown_series(period: period)
    values = series[:values]

    # One point per month, end date included
    assert_equal [ Date.new(2026, 6, 15), Date.new(2026, 7, 15), Date.new(2026, 8, 15), Date.new(2026, 9, 15) ],
      values.map { |point| point[:date] }

    values.each do |point|
      asset_sum = point[:groups].select { |g| g[:classification] == "asset" }.sum { |g| g[:value].amount }
      liability_sum = point[:groups].select { |g| g[:classification] == "liability" }.sum { |g| g[:value].amount }

      assert_equal asset_sum, point[:assets].amount
      assert_equal liability_sum, point[:liabilities].amount
      assert_equal point[:assets].amount - point[:liabilities].amount, point[:value].amount, "net worth on #{point[:date]}"
    end

    # Liabilities are positive amounts
    last = values.last
    assert_equal 206_000, last[:assets].amount
    assert_equal 51_500, last[:liabilities].amount
    assert_equal 154_500, last[:value].amount

    # The loan has no balance before August
    assert_equal 0, values.first[:groups].find { |g| g[:name] == I18n.t("accounts.types.loan") }[:value].amount

    # Each point's trend is the change from the previous month; the first is flat
    assert values.first[:trend].direction.flat?
    values.each_cons(2) do |previous, point|
      assert_equal point[:value].amount - previous[:value].amount, point[:trend].value.amount
    end

    # The series trend runs from the first point to the last
    assert_equal values.last[:value].amount - values.first[:value].amount, series[:trend].value.amount
  end

  test "groups carry a name and color, assets first, and empty groups are left out" do
    period = Period.custom(start_date: Date.new(2026, 8, 15), end_date: Date.new(2026, 9, 15))

    card = create_account(balance: 1_000, accountable: CreditCard.new)
    cash = create_account(balance: 5_000, accountable: Depository.new)
    create_account(balance: 0, accountable: Vehicle.new) # no balances at all

    create_balance(account: cash, date: period.end_date, balance: 5_000)
    create_balance(account: card, date: period.end_date, balance: 1_000)

    groups = builder.breakdown_series(period: period)[:values].last[:groups]

    assert_equal %w[asset liability], groups.map { |g| g[:classification] }
    assert_equal [ I18n.t("accounts.types.depository"), I18n.t("accounts.types.credit_card") ], groups.map { |g| g[:name] }
    assert_equal [ Depository.color, CreditCard.color ], groups.map { |g| g[:color] }
  end

  test "a disabled account counts only before it was disabled" do
    zone = @family.resolved_time_zone
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 9, 15))

    active = create_account(balance: 10_000, accountable: Depository.new)
    closed = create_account(balance: 4_000, accountable: Investment.new)
    draft = create_account(balance: 1_000, accountable: Property.new, status: "draft")

    [ active, closed, draft ].each do |account|
      create_balance(account: account, date: Date.new(2026, 6, 1), balance: account.balance)
    end

    # Disabled on Aug 1: it counts in June and July, not in August or September
    travel_to(zone.local(2026, 8, 1, 12)) { closed.disable! }

    travel_to zone.local(2026, 9, 15, 12) do
      values = builder.breakdown_series(period: period)[:values]

      assert_equal [ 14_000, 14_000, 10_000, 10_000 ], values.map { |point| point[:value].amount }

      investment = values.map { |point| point[:groups].find { |g| g[:name] == I18n.t("accounts.types.investment") }[:value].amount }
      assert_equal [ 4_000, 4_000, 0, 0 ], investment

      # The draft never counts
      assert_nil values.last[:groups].find { |g| g[:name] == I18n.t("accounts.types.property") }
    end
  end

  test "amounts are rounded to the currency's precision" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    cash = create_account(balance: 0, accountable: Depository.new)
    savings = create_account(balance: 0, accountable: Depository.new)
    card = create_account(balance: 0, accountable: CreditCard.new)

    # Both points print as $0.00 for the cash group; the line has to be flat
    create_balance(account: cash, date: period.start_date, balance: 0.0001)
    create_balance(account: cash, date: period.end_date, balance: 0.0002)
    create_balance(account: savings, date: period.start_date, balance: 10.004)
    create_balance(account: savings, date: period.end_date, balance: 10.004)
    create_balance(account: card, date: period.start_date, balance: 3.336)
    create_balance(account: card, date: period.end_date, balance: 3.336)

    values = builder.breakdown_series(period: period)[:values]

    values.each do |point|
      point[:groups].each { |group| assert_equal group[:value].amount.round(2), group[:value].amount }
      assert_equal BigDecimal("10.00"), point[:assets].amount
      assert_equal BigDecimal("3.34"), point[:liabilities].amount
      assert_equal BigDecimal("6.66"), point[:value].amount
      assert point[:trend].direction.flat?, "no change between values that print the same"
    end
  end

  test "an infinite percent serializes as null" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    cash = create_account(balance: 0, accountable: Depository.new)
    create_balance(account: cash, date: period.start_date, balance: 0.0001)
    create_balance(account: cash, date: period.end_date, balance: 1)

    series = builder.breakdown_series(period: period)
    parsed = JSON.parse(series.to_json)

    assert_equal 0, series[:values].first[:value].amount
    assert_equal 1, series[:values].last[:value].amount
    assert_nil parsed["values"].last["trend"]["percent"]
  end

  test "no accounts give no points" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 9, 15))

    series = builder.breakdown_series(period: period)

    assert_empty series[:values]
    assert_nil series[:trend]
  end

  test "the cache key carries the payload version" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    assert_includes builder.send(:cache_key, period), BalanceSheet::NetWorthBreakdownSeriesBuilder::CACHE_VERSION
  end

  private
    def builder
      BalanceSheet::NetWorthBreakdownSeriesBuilder.new(@family)
    end

    def create_account(attributes = {})
      # Reloaded so the generated classification column is read back
      @family.accounts.create!(name: "Test", **{ currency: "USD" }.merge(attributes)).reload
    end
end
