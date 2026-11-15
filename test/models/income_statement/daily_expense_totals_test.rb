require "test_helper"

class IncomeStatement::DailyExpenseTotalsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @family.update!(currency: "USD")
    @checking = @family.accounts.create! name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new
    @food = @family.categories.create! name: "Food", classification: "expense"
    @groceries = @family.categories.create! name: "Groceries", classification: "expense", parent: @food
    @salary = @family.categories.create! name: "Salary", classification: "income"
    @period = Period.custom(start_date: 9.days.ago.to_date, end_date: Date.current)
  end

  # --- The query ---

  test "rows are signed per day and category" do
    create_transaction(account: @checking, amount: 100, date: 2.days.ago.to_date, category: @food)
    create_transaction(account: @checking, amount: 50, date: 2.days.ago.to_date, category: @food)
    create_transaction(account: @checking, amount: -30, date: Date.current, category: @food)
    create_transaction(account: @checking, amount: 25, date: Date.current)

    rows = query_rows

    assert_equal 150, row_amount(rows, 2.days.ago.to_date, @food.id)
    assert_equal(-30, row_amount(rows, Date.current, @food.id))
    assert_equal 25, row_amount(rows, Date.current, nil)
    assert_equal rows.map(&:date).sort, rows.map(&:date)
  end

  test "the kinds budgets leave out, pending and excluded entries stay out" do
    create_transaction(account: @checking, amount: 40, kind: "funds_movement")
    create_transaction(account: @checking, amount: 30, kind: "cc_payment")
    create_transaction(account: @checking, amount: 20, kind: "one_time")
    pending = create_transaction(account: @checking, amount: 15)
    pending.entryable.update!(extra: { "manual" => { "pending" => true } })
    create_transaction(account: @checking, amount: 12, excluded: true)
    create_transaction(account: @checking, amount: 10, kind: "loan_payment")

    assert_equal 10, query_rows.sum(&:amount)
  end

  test "an investment contribution counts as spending whatever its sign" do
    create_transaction(account: @checking, amount: -300, kind: "investment_contribution")

    assert_equal 300, query_rows.sum(&:amount)
  end

  test "an entry in a currency with no rate is left out, never counted at 1" do
    eur = @family.accounts.create! name: "EUR", currency: "EUR", balance: 0, accountable: Depository.new
    create_transaction(account: eur, amount: 100, currency: "EUR")
    create_transaction(account: @checking, amount: 10)

    assert_equal 10, query_rows.sum(&:amount)
  end

  test "an entry converts at the nearest earlier rate" do
    eur = @family.accounts.create! name: "EUR", currency: "EUR", balance: 0, accountable: Depository.new
    ExchangeRate.create! from_currency: "EUR", to_currency: "USD", date: 20.days.ago.to_date, rate: 2
    create_transaction(account: eur, amount: 100, currency: "EUR")

    assert_equal 200, query_rows.sum(&:amount)
  end

  # --- IncomeStatement#daily_expense_series ---

  test "refunds net within their category on the day they land" do
    create_transaction(account: @checking, amount: 100, date: 3.days.ago.to_date, category: @groceries)
    create_transaction(account: @checking, amount: -30, date: 1.day.ago.to_date, category: @groceries)

    series = income_statement.daily_expense_series(period: @period)

    assert_equal 100, series[3.days.ago.to_date]
    assert_equal(-30, series[1.day.ago.to_date])
    assert_equal 70, series.values.sum
  end

  test "a category that nets to income stays out of the spending curve" do
    create_transaction(account: @checking, amount: -1000, category: @salary)
    # Refunded more than spent: no spending this period, as in the Sankey
    create_transaction(account: @checking, amount: 20, date: 2.days.ago.to_date, category: @food)
    create_transaction(account: @checking, amount: -50, date: 1.day.ago.to_date, category: @food)
    create_transaction(account: @checking, amount: 40, category: @groceries)

    series = income_statement.daily_expense_series(period: @period)

    assert_equal 40, series.values.sum
    assert_equal [ @groceries.id ], income_statement.daily_expense_category_ids(period: @period)
  end

  test "the curve ends at the netted spending total of the period" do
    create_transaction(account: @checking, amount: 200, category: @groceries)
    create_transaction(account: @checking, amount: -50, category: @groceries)
    create_transaction(account: @checking, amount: 80, category: @food)
    create_transaction(account: @checking, amount: 15)
    create_transaction(account: @checking, amount: -1000, category: @salary)

    statement = income_statement
    netted = IncomeStatement::CategoryNetting.new(statement, period: @period).groups
      .sum { |group| IncomeStatement::CategoryNetting.side_total(group, :expense) }

    assert_equal netted, statement.daily_expense_series(period: @period).values.sum
  end

  test "a parent in the category filter covers its subcategories" do
    other = @family.categories.create! name: "Travel", classification: "expense"
    create_transaction(account: @checking, amount: 100, category: @groceries)
    create_transaction(account: @checking, amount: 10, category: @food)
    create_transaction(account: @checking, amount: 7, category: other)
    create_transaction(account: @checking, amount: 3)

    statement = income_statement

    assert_equal 110, statement.daily_expense_series(period: @period, category_ids: [ @food.id ]).values.sum
    assert_equal 100, statement.daily_expense_series(period: @period, category_ids: [ @groceries.id ]).values.sum
    assert_equal 3, statement.daily_expense_series(period: @period, category_ids: [ Category::UNCATEGORIZED_FILTER_VALUE ]).values.sum
    assert_equal 120, statement.daily_expense_series(period: @period).values.sum
  end

  # --- IncomeStatement::SpendingTrend on fiscal months ---

  test "fiscal month start day 5: the period runs from the 5th and the header compares the same days so far" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    travel_to Date.new(2026, 3, 12) do
      create_transaction(account: @checking, amount: 100, date: Date.new(2026, 2, 6), category: @food)
      create_transaction(account: @checking, amount: 300, date: Date.new(2026, 2, 20), category: @food)
      create_transaction(account: @checking, amount: 80, date: Date.new(2026, 3, 6), category: @food)
      create_transaction(account: @checking, amount: -30, date: Date.new(2026, 3, 8), category: @food)
      # Before the fiscal period starts: last period
      create_transaction(account: @checking, amount: 999, date: Date.new(2026, 3, 4), category: @groceries)

      trend = IncomeStatement::SpendingTrend.new(IncomeStatement.new(@family), date: Date.current)

      assert_equal Date.new(2026, 3, 5), trend.period_start
      assert_equal Date.new(2026, 4, 4), trend.period_end
      assert_equal 31, trend.axis_days
      assert_equal Date.new(2026, 2, 5)..Date.new(2026, 3, 4), trend.previous_period.date_range
      assert trend.in_progress?

      # The selected period stops at today; the refund nets on its day
      assert_equal 8, trend.current_points.size
      assert_equal 50, trend.current_total
      assert_equal [ 0, 80, 80, 50 ], trend.current_points.first(4).map { |point| point[:value] }

      # Day 1 to 8 of each period: Feb 5 to Feb 12 holds only the 100
      assert_equal 8, trend.comparison_days
      assert_equal 100, trend.previous_total
      assert_equal Date.new(2026, 2, 12), trend.comparison_end_date
      assert trend.partial_comparison?
      assert_equal(-50, trend.delta)
    end
  end

  test "a finished fiscal period compares with the whole previous period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    travel_to Date.new(2026, 4, 20) do
      create_transaction(account: @checking, amount: 100, date: Date.new(2026, 2, 6), category: @food)
      create_transaction(account: @checking, amount: 300, date: Date.new(2026, 3, 4), category: @food)
      create_transaction(account: @checking, amount: 70, date: Date.new(2026, 3, 30), category: @food)

      trend = IncomeStatement::SpendingTrend.new(IncomeStatement.new(@family), date: Date.new(2026, 3, 10))

      assert_not trend.in_progress?
      assert_equal 31, trend.current_points.size
      assert_equal 70, trend.current_total
      assert_equal 400, trend.previous_total
      assert_not trend.partial_comparison?
    end
  end

  test "a longer previous period folds its extra days into the last axis point" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    travel_to Date.new(2026, 3, 20) do
      # Feb 5 to Mar 4 is 28 days; Jan 5 to Feb 4 is 31
      create_transaction(account: @checking, amount: 100, date: Date.new(2026, 1, 6), category: @food)
      create_transaction(account: @checking, amount: 60, date: Date.new(2026, 2, 3), category: @food)

      trend = IncomeStatement::SpendingTrend.new(IncomeStatement.new(@family), date: Date.new(2026, 2, 10))
      points = trend.previous_axis_points

      assert_equal 28, trend.axis_days
      assert_equal 28, points.size
      assert_equal 160, points.last[:value]
      assert_equal Date.new(2026, 2, 4), points.last[:date]
      assert_equal 160, trend.previous_total
    end
  end

  test "a future period date shows the current period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    travel_to Date.new(2026, 3, 12) do
      trend = IncomeStatement::SpendingTrend.new(IncomeStatement.new(@family), date: Date.new(2026, 9, 1))

      assert_equal Date.new(2026, 3, 5), trend.period_start
      assert_equal Date.new(2026, 3, 5), IncomeStatement::SpendingTrend.recent_period_starts(@family).first
      assert_equal Date.new(2026, 2, 5), IncomeStatement::SpendingTrend.recent_period_starts(@family).second
    end
  end

  private
    def income_statement
      IncomeStatement.new(@family)
    end

    def query_rows
      IncomeStatement::DailyExpenseTotals.new(
        @family,
        transactions_scope: @family.transactions.visible.excluding_pending.in_period(@period),
        date_range: @period.date_range
      ).call
    end

    def row_amount(rows, date, category_id)
      rows.select { |row| row.date == date && row.category_id == category_id }.sum(&:amount)
    end
end
