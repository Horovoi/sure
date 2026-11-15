require "test_helper"

class PeriodTest < ActiveSupport::TestCase
  test "raises validation error when start_date or end_date is missing" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: nil, end_date: nil)
    end

    assert_includes error.message, "Start date can't be blank"
    assert_includes error.message, "End date can't be blank"
  end

  test "raises validation error when start_date is not before end_date" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: Date.current, end_date: Date.current - 1.day)
    end

    assert_includes error.message, "Start date must be before end date"
  end

  test "can create custom period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "from_key returns period for valid key" do
    period = Period.from_key("last_30_days")
    assert_equal 30.days.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "from_key with invalid key and no fallback raises error" do
    error = assert_raises(Period::InvalidKeyError) do
      Period.from_key("invalid_key")
    end
  end

  test "label returns correct label for known period" do
    period = Period.from_key("last_30_days")
    assert_equal "Last 30 Days", period.label
  end

  test "label returns Custom Period for unknown period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "all_time period can be created" do
    period = Period.from_key("all_time")
    assert_equal "all_time", period.key
    assert_equal "All Time", period.label
    assert_equal "All", period.label_short
  end

  test "all_time period starts one month before the family's earliest activity" do
    mock_family = mock("family")
    mock_family.expects(:earliest_activity_date).returns(2.years.ago.to_date)
    Current.expects(:family).at_least_once.returns(mock_family)

    period = Period.from_key("all_time")
    assert_equal 2.years.ago.to_date - 1.month, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period uses fallback when no family or entries exist" do
    Current.expects(:family).returns(nil)

    period = Period.from_key("all_time")
    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period uses fallback when oldest_entry_date equals current date" do
    # A family with no entries at all: no activity, and oldest_entry_date is today
    mock_family = mock("family")
    mock_family.expects(:earliest_activity_date).returns(nil)
    mock_family.expects(:oldest_entry_date).returns(Date.current)
    Current.expects(:family).at_least_once.returns(mock_family)

    period = Period.from_key("all_time")
    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "interval is daily for one year" do
    assert_equal "1 day", Period.from_key("last_365_days").interval
    assert_equal "1 day", Period.custom(start_date: Date.new(2025, 1, 1), end_date: Date.new(2026, 1, 1)).interval
  end

  test "interval is weekly for 5 years and for 2 years" do
    assert_equal "1 week", Period.from_key("last_5_years").interval
    assert_equal "1 week", Period.custom(start_date: Date.new(2020, 3, 1), end_date: Date.new(2025, 3, 1)).interval
    assert_equal "1 week", Period.custom(start_date: Date.new(2024, 1, 1), end_date: Date.new(2026, 1, 1)).interval
  end

  test "interval is monthly for more than 5 calendar years" do
    assert_equal "1 month", Period.custom(start_date: Date.new(2020, 3, 1), end_date: Date.new(2025, 3, 2)).interval
    assert_equal "1 month", Period.custom(start_date: Date.new(2015, 1, 1), end_date: Date.new(2026, 1, 1)).interval
  end

  test "interval thresholds use calendar years across a leap day" do
    # 2024-02-29 plus one calendar year is 2025-02-28, plus five is 2029-02-28
    leap_start = Date.new(2024, 2, 29)

    assert_equal "1 day", Period.custom(start_date: leap_start, end_date: Date.new(2025, 2, 28)).interval
    assert_equal "1 week", Period.custom(start_date: leap_start, end_date: Date.new(2025, 3, 1)).interval
    assert_equal "1 week", Period.custom(start_date: leap_start, end_date: Date.new(2029, 2, 28)).interval
    assert_equal "1 month", Period.custom(start_date: leap_start, end_date: Date.new(2029, 3, 1)).interval
  end

  test "all_time period starts one month before the first transaction or trade" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "UAH", accountable: Depository.new)
    account.entries.create!(date: Date.new(2025, 3, 10), name: "Groceries",
                            amount: -50, currency: "UAH", entryable: Transaction.new)
    trade_date = Date.new(2024, 6, 15)
    account.entries.create!(date: trade_date, name: "Investment purchase",
                            amount: 100, currency: "UAH",
                            entryable: Trade.new(security: securities(:aapl), qty: 1, price: 100, currency: "UAH"))

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal trade_date - 1.month, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period is not moved back by an old valuation" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "UAH", accountable: Depository.new)
    account.entries.create!(date: Date.new(2000, 1, 15), name: "Old valuation",
                            amount: 5000, currency: "UAH", entryable: Valuation.new)
    first_transaction_date = Date.new(2025, 3, 10)
    account.entries.create!(date: first_transaction_date, name: "Groceries",
                            amount: -50, currency: "UAH", entryable: Transaction.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal first_transaction_date - 1.month, period.start_date
  end

  test "all_time period anchors one month back when the first activity is today" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "UAH", accountable: Depository.new)
    account.entries.create!(date: Date.current, name: "First transaction",
                            amount: -50, currency: "UAH", entryable: Transaction.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal Date.current - 1.month, period.start_date
  end

  test "all_time period falls back to the oldest entry for a valuation-only family" do
    family = families(:empty)
    account = family.accounts.create!(name: "House", balance: 0, currency: "UAH", accountable: Depository.new)
    valuation_date = Date.new(2000, 1, 15)
    account.entries.create!(date: valuation_date, name: "Old valuation",
                            amount: 5000, currency: "UAH", entryable: Valuation.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal valuation_date, period.start_date
  end

  test "all_time period uses the 5-year fallback for a family with no entries" do
    family = families(:empty)
    assert_empty family.entries

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end
end
