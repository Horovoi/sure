require "test_helper"

class Assistant::Function::GetIncomeStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetIncomeStatement.new(@user)
    @params = { "start_date" => 1.year.ago.to_date.to_s, "end_date" => Date.current.to_s }
  end

  test "has correct name and is not strict" do
    assert_equal "get_income_statement", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "happy path shape is unchanged" do
    result = @fn.call(@params)

    assert result[:income][:total].present?
    assert result[:expense][:total].present?
    assert result[:income].key?(:by_category)
    assert result[:insights][:net_income].present?
    assert_not result.key?(:monthly_series)
    assert_not result.key?(:previous_period)
  end

  test "totals for the current fiscal month equal IncomeStatement for the same period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)
    start_date = @family.budget_period_start_for(Date.current)
    account = accounts(:depository)
    account.entries.create!(name: "Groceries this fiscal month", date: start_date, amount: 75, currency: "USD",
      entryable: Transaction.new(category: categories(:food_and_drink)))
    account.entries.create!(name: "Salary this fiscal month", date: start_date, amount: -500, currency: "USD",
      entryable: Transaction.new)
    account.entries.create!(name: "Groceries before the fiscal month", date: start_date - 1.day, amount: 33, currency: "USD",
      entryable: Transaction.new(category: categories(:food_and_drink)))

    period = Period.custom(start_date: start_date, end_date: Date.current)
    statement = IncomeStatement.new(@family)

    result = @fn.call("start_date" => start_date.to_s, "end_date" => Date.current.to_s)

    assert_equal Money.new(statement.expense_totals(period: period).total, @family.currency).format, result[:expense][:total]
    assert_equal Money.new(statement.income_totals(period: period).total, @family.currency).format, result[:income][:total]
  end

  test "group_by month returns one bucket per budget month" do
    result = @fn.call("start_date" => "2025-01-15", "end_date" => "2025-03-10", "group_by" => "month")
    series = result[:monthly_series]

    assert_equal 3, series.size
    assert_equal Date.parse("2025-01-15"), series.first[:start_date]
    assert_equal Date.parse("2025-01-31"), series.first[:end_date]
    assert_equal Date.parse("2025-03-10"), series.last[:end_date]
    series.each do |bucket|
      assert bucket[:income].present?
      assert bucket[:expenses].present?
      assert bucket[:net].present?
    end
  end

  test "group_by month follows the fiscal start day" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    series = @fn.call("start_date" => "2025-01-25", "end_date" => "2025-03-24", "group_by" => "month")[:monthly_series]

    assert_equal [ Date.parse("2025-01-25"), Date.parse("2025-02-25") ], series.map { |b| b[:start_date] }
    assert_equal [ Date.parse("2025-02-24"), Date.parse("2025-03-24") ], series.map { |b| b[:end_date] }
  end

  test "group_by month caps the bucket count" do
    result = @fn.call("start_date" => "2020-01-01", "end_date" => "2025-12-31", "group_by" => "month")

    assert_equal "too_many_periods", result[:error]
  end

  test "monthly buckets add up to the full statement" do
    account = accounts(:depository)
    account.entries.create!(name: "January spend", date: Date.new(2025, 1, 10), amount: 40, currency: "USD", entryable: Transaction.new)
    account.entries.create!(name: "February spend", date: Date.new(2025, 2, 10), amount: 60, currency: "USD", entryable: Transaction.new)

    result = @fn.call("start_date" => "2025-01-01", "end_date" => "2025-02-28", "group_by" => "month")

    assert_equal [ Money.new(40, "USD").format, Money.new(60, "USD").format ], result[:monthly_series].map { |b| b[:expenses] }
    assert_equal Money.new(100, "USD").format, result[:expense][:total]
  end

  test "compare_previous_period returns an equal-length prior window with deltas" do
    previous = @fn.call("start_date" => "2025-06-01", "end_date" => "2025-06-30", "compare_previous_period" => true)[:previous_period]

    assert_equal Date.parse("2025-05-02"), previous[:start_date]
    assert_equal Date.parse("2025-05-31"), previous[:end_date]
    assert previous[:income_change].key?(:amount)
    assert previous[:expenses_change].key?(:percent)
  end

  test "account_ids scopes totals and omits the category breakdown" do
    account = accounts(:depository)
    account.entries.create!(name: "Checking spend", date: Date.current, amount: 70, currency: "USD", entryable: Transaction.new)
    accounts(:credit_card).entries.create!(name: "Card spend", date: Date.current, amount: 900, currency: "USD", entryable: Transaction.new)

    result = @fn.call(@params.merge("account_ids" => [ account.id ]))

    assert_nil result[:income][:by_category]
    assert result[:breakdown_omitted_reason].present?
    assert result[:net].present?
    # The fixture Starbucks purchase (10) plus this one; the card payment is a transfer and the card spend is
    # on another account
    assert_equal Money.new(80, "USD").format, result[:expense][:total]
  end

  test "unknown or non-UUID account ids return a soft failure naming them" do
    bogus = SecureRandom.uuid

    result = @fn.call(@params.merge("account_ids" => [ bogus, "not-a-uuid" ]))

    assert_equal "unknown_account_ids", result[:error]
    assert_equal [ bogus, "not-a-uuid" ], result[:unknown_ids]
    assert result[:hint].present?
  end

  test "hidden accounts are rejected instead of returning silent zeros" do
    hidden = accounts(:depository)
    hidden.update!(status: "disabled")

    result = @fn.call(@params.merge("account_ids" => [ hidden.id ]))

    assert_equal "unknown_account_ids", result[:error]
  end

  test "invalid dates return an invalid_date error" do
    assert_equal "invalid_date", @fn.call("start_date" => "bogus", "end_date" => "2024-01-01")[:error]
    assert_equal "invalid_date", @fn.call("start_date" => "2025-02-01", "end_date" => "2025-01-01")[:error]
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "an account excluded from reports is rejected as an account filter, not answered with zeros" do
    excluded = accounts(:depository)
    excluded.update!(exclude_from_reports: true)

    result = @fn.call(@params.merge("account_ids" => [ excluded.id ]))

    assert_equal "unknown_account_ids", result[:error]
    assert_equal [ excluded.id ], result[:unknown_ids]
  end

  test "the full statement leaves out an account excluded from reports" do
    accounts(:credit_card).entries.create!(name: "Card spend", date: Date.current, amount: 900, currency: "USD", entryable: Transaction.new)
    with_card = @fn.call(@params)[:expense][:total]

    accounts(:credit_card).update!(exclude_from_reports: true)
    without_card = Assistant::Function::GetIncomeStatement.new(@user).call(@params)[:expense][:total]

    assert_not_equal with_card, without_card
  end
end
