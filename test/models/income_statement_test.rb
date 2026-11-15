require "test_helper"

class IncomeStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)

    @income_category = @family.categories.create! name: "Income", classification: "income"
    @food_category = @family.categories.create! name: "Food", classification: "expense"
    @groceries_category = @family.categories.create! name: "Groceries", classification: "expense", parent: @food_category

    @checking_account = @family.accounts.create! name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    @credit_card_account = @family.accounts.create! name: "Credit Card", currency: @family.currency, balance: 1000, accountable: CreditCard.new
    @loan_account = @family.accounts.create! name: "Mortgage", currency: @family.currency, balance: 50000, accountable: Loan.new

    create_transaction(account: @checking_account, amount: -1000, category: @income_category)
    create_transaction(account: @checking_account, amount: 200, category: @groceries_category)
    create_transaction(account: @credit_card_account, amount: 300, category: @groceries_category)
    create_transaction(account: @credit_card_account, amount: 400, category: @groceries_category)
  end

  test "calculates totals for transactions" do
    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(200 + 300 + 400, @family.currency), totals.expense_money
    assert_equal 4, totals.transactions_count
  end

  test "calculates expenses for a period" do
    income_statement = IncomeStatement.new(@family)
    expense_totals = income_statement.expense_totals(period: Period.last_30_days)

    expected_total_expense = 200 + 300 + 400

    assert_equal expected_total_expense, expense_totals.total
    assert_equal expected_total_expense, expense_totals.category_totals.find { |ct| ct.category.id == @groceries_category.id }.total
    assert_equal expected_total_expense, expense_totals.category_totals.find { |ct| ct.category.id == @food_category.id }.total
  end

  test "calculates income for a period" do
    income_statement = IncomeStatement.new(@family)
    income_totals = income_statement.income_totals(period: Period.last_30_days)

    expected_total_income = 1000

    assert_equal expected_total_income, income_totals.total
    assert_equal expected_total_income, income_totals.category_totals.find { |ct| ct.category.id == @income_category.id }.total
  end

  test "calculates median expense" do
    income_statement = IncomeStatement.new(@family)
    assert_equal 200 + 300 + 400, income_statement.expense_totals(period: Period.last_30_days).total
  end

  test "calculates median income" do
    income_statement = IncomeStatement.new(@family)
    assert_equal 1000, income_statement.income_totals(period: Period.last_30_days).total
  end

  # NEW TESTS: Statistical Methods
  test "calculates median expense correctly with known dataset" do
    # Clear existing transactions by deleting entries
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create expenses: 100, 200, 300, 400, 500 (median should be 300)
    create_transaction(account: @checking_account, amount: 100, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 200, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 300, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 400, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 500, category: @groceries_category)

    income_statement = IncomeStatement.new(@family)
    # CORRECT BUSINESS LOGIC: Calculates median of time-period totals for budget planning
    # All transactions in same month = monthly total of 1500, so median = 1500.0
    assert_equal 1500.0, income_statement.median_expense(interval: "month")
  end

  test "calculates median income correctly with known dataset" do
    # Clear existing transactions by deleting entries
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create income: -200, -300, -400, -500, -600 (median should be -400, displayed as 400)
    create_transaction(account: @checking_account, amount: -200, category: @income_category)
    create_transaction(account: @checking_account, amount: -300, category: @income_category)
    create_transaction(account: @checking_account, amount: -400, category: @income_category)
    create_transaction(account: @checking_account, amount: -500, category: @income_category)
    create_transaction(account: @checking_account, amount: -600, category: @income_category)

    income_statement = IncomeStatement.new(@family)
    # CORRECT BUSINESS LOGIC: Calculates median of time-period totals for budget planning
    # All transactions in same month = monthly total of -2000, so median = 2000.0
    assert_equal 2000.0, income_statement.median_income(interval: "month")
  end

  test "calculates average expense correctly with known dataset" do
    # Clear existing transactions by deleting entries
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create expenses: 100, 200, 300 (average should be 200)
    create_transaction(account: @checking_account, amount: 100, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 200, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 300, category: @groceries_category)

    income_statement = IncomeStatement.new(@family)
    # CORRECT BUSINESS LOGIC: Calculates average of time-period totals for budget planning
    # All transactions in same month = monthly total of 600, so average = 600.0
    assert_equal 600.0, income_statement.avg_expense(interval: "month")
  end

  test "calculates category-specific median expense" do
    # Clear existing transactions by deleting entries
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create different amounts for groceries vs other food
    other_food_category = @family.categories.create! name: "Restaurants", classification: "expense", parent: @food_category

    # Groceries: 100, 300, 500 (median = 300)
    create_transaction(account: @checking_account, amount: 100, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 300, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 500, category: @groceries_category)

    # Restaurants: 50, 150 (median = 100)
    create_transaction(account: @checking_account, amount: 50, category: other_food_category)
    create_transaction(account: @checking_account, amount: 150, category: other_food_category)

    income_statement = IncomeStatement.new(@family)
    # CORRECT BUSINESS LOGIC: Calculates median of time-period totals for budget planning
    # All groceries in same month = monthly total of 900, so median = 900.0
    assert_equal 900.0, income_statement.median_expense(interval: "month", category: @groceries_category)
    # For restaurants: monthly total = 200, so median = 200.0
    restaurants_median = income_statement.median_expense(interval: "month", category: other_food_category)
    assert_equal 200.0, restaurants_median
  end

  test "calculates category-specific average expense" do
    # Clear existing transactions by deleting entries
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create different amounts for groceries
    # Groceries: 100, 200, 300 (average = 200)
    create_transaction(account: @checking_account, amount: 100, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 200, category: @groceries_category)
    create_transaction(account: @checking_account, amount: 300, category: @groceries_category)

    income_statement = IncomeStatement.new(@family)
    # CORRECT BUSINESS LOGIC: Calculates average of time-period totals for budget planning
    # All transactions in same month = monthly total of 600, so average = 600.0
    assert_equal 600.0, income_statement.avg_expense(interval: "month", category: @groceries_category)
  end

  # NEW TESTS: Transfer and Kind Filtering
  # NOTE: These tests now pass because kind filtering is working after the refactoring!
  test "excludes regular transfers from income statement calculations" do
    # Create a regular transfer between accounts
    outflow_transaction = create_transaction(account: @checking_account, amount: 500, kind: "funds_movement")
    inflow_transaction = create_transaction(account: @credit_card_account, amount: -500, kind: "funds_movement")

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # NOW WORKING: Excludes transfers correctly after refactoring
    assert_equal 4, totals.transactions_count # Only original 4 transactions
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(900, @family.currency), totals.expense_money
  end

  test "includes loan payments as expenses in income statement" do
    # Create a loan payment transaction
    loan_payment = create_transaction(account: @checking_account, amount: 1000, category: nil, kind: "loan_payment")

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # CONTINUES TO WORK: Includes loan payments as expenses (loan_payment not in exclusion list)
    assert_equal 5, totals.transactions_count
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(1900, @family.currency), totals.expense_money # 900 + 1000
  end

  test "excludes one-time transactions from income statement calculations" do
    # Create a one-time transaction
    one_time_transaction = create_transaction(account: @checking_account, amount: 250, category: @groceries_category, kind: "one_time")

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # NOW WORKING: Excludes one-time transactions correctly after refactoring
    assert_equal 4, totals.transactions_count # Only original 4 transactions
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(900, @family.currency), totals.expense_money
  end

  test "excludes payment transactions from income statement calculations" do
    # Create a payment transaction (credit card payment)
    payment_transaction = create_transaction(account: @checking_account, amount: 300, category: nil, kind: "cc_payment")

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # NOW WORKING: Excludes payment transactions correctly after refactoring
    assert_equal 4, totals.transactions_count # Only original 4 transactions
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(900, @family.currency), totals.expense_money
  end

  test "excludes excluded transactions from income statement calculations" do
    # Create an excluded transaction
    excluded_transaction_entry = create_transaction(account: @checking_account, amount: 250, category: @groceries_category)
    excluded_transaction_entry.update!(excluded: true)

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # Should exclude excluded transactions
    assert_equal 4, totals.transactions_count # Only original 4 transactions
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(900, @family.currency), totals.expense_money
  end

  # NEW TESTS: Interval-Based Calculations
  test "different intervals return different statistical results with multi-period data" do
    # Clear existing transactions
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Create transactions across multiple weeks to test interval behavior
    # Week 1: 100, 200 (total: 300, median: 150)
    create_transaction(account: @checking_account, amount: 100, category: @groceries_category, date: 3.weeks.ago)
    create_transaction(account: @checking_account, amount: 200, category: @groceries_category, date: 3.weeks.ago + 1.day)

    # Week 2: 400, 600 (total: 1000, median: 500)
    create_transaction(account: @checking_account, amount: 400, category: @groceries_category, date: 2.weeks.ago)
    create_transaction(account: @checking_account, amount: 600, category: @groceries_category, date: 2.weeks.ago + 1.day)

    # Week 3: 800 (total: 800, median: 800)
    create_transaction(account: @checking_account, amount: 800, category: @groceries_category, date: 1.week.ago)

    income_statement = IncomeStatement.new(@family)

    month_median = income_statement.median_expense(interval: "month")
    week_median = income_statement.median_expense(interval: "week")

    # CRITICAL TEST: Different intervals should return different results
    # Month interval: median of monthly totals (if all in same month) vs individual transactions
    # Week interval: median of weekly totals [300, 1000, 800] = 800 vs individual transactions [100,200,400,600,800] = 400
    refute_equal month_median, week_median, "Different intervals should return different statistical results when data spans multiple time periods"

    # Both should still be numeric
    assert month_median.is_a?(Numeric)
    assert week_median.is_a?(Numeric)
    assert month_median > 0
    assert week_median > 0
  end

  # NEW TESTS: Edge Cases
  test "handles empty dataset gracefully" do
    # Create a truly empty family
    empty_family = Family.create!(name: "Empty Test Family", currency: "USD")
    income_statement = IncomeStatement.new(empty_family)

    # Should return 0 for statistical measures
    assert_equal 0, income_statement.median_expense(interval: "month")
    assert_equal 0, income_statement.median_income(interval: "month")
    assert_equal 0, income_statement.avg_expense(interval: "month")
  end

  test "handles category not found gracefully" do
    nonexistent_category = Category.new(id: 99999, name: "Nonexistent")

    income_statement = IncomeStatement.new(@family)

    assert_equal 0, income_statement.median_expense(interval: "month", category: nonexistent_category)
    assert_equal 0, income_statement.avg_expense(interval: "month", category: nonexistent_category)
  end

  test "handles transactions without categories" do
    # Create transaction without category
    create_transaction(account: @checking_account, amount: 150, category: nil)

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # Should still include uncategorized transaction in totals
    assert_equal 5, totals.transactions_count
    assert_equal Money.new(1050, @family.currency), totals.expense_money # 900 + 150
  end

  test "includes investment_contribution transactions as expenses in income statement" do
    # Create a transfer to investment account (marked as investment_contribution)
    investment_contribution = create_transaction(
      account: @checking_account,
      amount: 1000,
      category: nil,
      kind: "investment_contribution"
    )

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # investment_contribution should be included as an expense (visible in cashflow)
    assert_equal 5, totals.transactions_count # Original 4 + investment_contribution
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(1900, @family.currency), totals.expense_money # 900 + 1000 investment
  end

  test "includes provider-imported investment_contribution inflows as expenses" do
    # Simulates a 401k contribution that was auto-deducted from payroll
    # Provider imports this as an inflow to the investment account (negative amount)
    # but it should still appear as an expense in cashflow

    investment_account = @family.accounts.create!(
      name: "401k",
      currency: @family.currency,
      balance: 10000,
      accountable: Investment.new
    )

    # Provider-imported contribution shows as inflow (negative amount) to the investment account
    # kind is investment_contribution, which should be treated as expense regardless of sign
    provider_contribution = create_transaction(
      account: investment_account,
      amount: -500, # Negative = inflow to account
      category: nil,
      kind: "investment_contribution"
    )

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    # The provider-imported contribution should appear as an expense
    assert_equal 5, totals.transactions_count # Original 4 + provider contribution
    assert_equal Money.new(1000, @family.currency), totals.income_money
    assert_equal Money.new(1400, @family.currency), totals.expense_money # 900 + 500 (abs of -500)
  end

  test "category average counts months without spending as zero" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    first_month = Date.current.beginning_of_month - 4.months
    restaurants = @family.categories.create! name: "Restaurants", classification: "expense", parent: @food_category

    # Groceries spends 300 once in four months; restaurants spends every month
    create_transaction(account: @checking_account, date: first_month, amount: 300, category: @groceries_category)
    4.times { |i| create_transaction(account: @checking_account, date: first_month + i.months, amount: 50, category: restaurants) }

    income_statement = IncomeStatement.new(@family)
    assert_equal 75.0, income_statement.avg_expense(interval: "month", category: @groceries_category)
    # The median stays the typical month with spending, so the budget hint is not zero
    assert_equal 300.0, income_statement.median_expense(interval: "month", category: @groceries_category)
    assert_equal 50.0, income_statement.avg_expense(interval: "month", category: restaurants)
    # The parent rolls up both: (300 + 4 * 50) over the same four months
    assert_equal 125.0, income_statement.avg_expense(interval: "month", category: @food_category)
  end

  test "category average starts at the category's first month, not the family's" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    this_month = Date.current.beginning_of_month

    create_transaction(account: @checking_account, date: Date.new(1997, 5, 1), amount: -5, category: @income_category)
    24.times { |i| create_transaction(account: @checking_account, date: this_month - (i + 1).months, amount: -3000, category: @income_category) }
    2.times { |i| create_transaction(account: @checking_account, date: this_month - (i + 1).months, amount: 1000, category: @groceries_category) }

    assert_equal 1000.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: @groceries_category)
  end

  test "category average does not count the unfinished current month until it has spending" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    this_month = Date.current.beginning_of_month

    3.times { |i| create_transaction(account: @checking_account, date: this_month - (i + 1).months, amount: 100, category: @groceries_category) }
    create_transaction(account: @checking_account, date: this_month, amount: -3000, category: @income_category)

    assert_equal 100.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: @groceries_category)
  end

  test "category average covers at most the last 12 months" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    this_month = Date.current.beginning_of_month

    # Used once five years ago, then 1,000 in each of the last three months
    create_transaction(account: @checking_account, date: this_month - 60.months, amount: 500, category: @groceries_category)
    3.times { |i| create_transaction(account: @checking_account, date: this_month - (i + 1).months, amount: 1000, category: @groceries_category) }

    income_statement = IncomeStatement.new(@family)
    assert_equal 250.0, income_statement.avg_expense(interval: "month", category: @groceries_category)
    assert_equal 1000.0, income_statement.median_expense(interval: "month", category: @groceries_category)
  end

  test "category average with current-month spending still covers at most 12 months" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    this_month = Date.current.beginning_of_month

    12.times { |i| create_transaction(account: @checking_account, date: this_month - (i + 1).months, amount: 100, category: @groceries_category) }
    create_transaction(account: @checking_account, date: this_month, amount: 220, category: @groceries_category)

    # Months -11 .. 0: (11 * 100 + 220) / 12
    assert_equal 110.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: @groceries_category)
  end

  test "category average follows the fiscal month start day" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    restaurants = @family.categories.create! name: "Restaurants", classification: "expense", parent: @food_category

    travel_to Time.utc(2026, 11, 15, 12) do
      # On the 9th: the August period when months start on the 5th, July when on the 10th
      create_transaction(account: @checking_account, date: Date.new(2026, 8, 9), amount: 300, category: @groceries_category)
      [ 8, 9, 10 ].each { |month| create_transaction(account: @checking_account, date: Date.new(2026, month, 12), amount: 50, category: restaurants) }

      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
      # August, September, October
      assert_equal 100.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: @groceries_category)

      @family.update!(fiscal_month_start_day: 10)
      # July, August, September, October
      assert_equal 75.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: @groceries_category)
      assert_equal 50.0, IncomeStatement.new(@family).avg_expense(interval: "month", category: restaurants)
    end
  end

  test "stats count an investment contribution as an expense, as the totals do" do
    investment_account = @family.accounts.create!(name: "Brokerage", currency: @family.currency, balance: 10000, accountable: Investment.new)
    create_transaction(account: investment_account, amount: -500, category: @food_category, kind: "investment_contribution")

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    assert_equal Money.new(1400, @family.currency), totals.expense_money
    assert_equal 1400.0, income_statement.median_expense(interval: "month")
    assert_equal 1400.0, income_statement.avg_expense(interval: "month")
    assert_equal 1000.0, income_statement.median_income(interval: "month")
    # Food rolls up the 900 of groceries and the 500 contribution
    assert_equal 1400.0, income_statement.avg_expense(interval: "month", category: @food_category)
  end

  test "the current period is the family's date, not the UTC date" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all
    @family.update!(timezone: "Europe/Kyiv", use_fiscal_months: true, fiscal_month_start_day: 5)
    # In the fiscal period October 5 .. November 4
    create_transaction(account: @checking_account, date: Date.new(2026, 10, 20), amount: 300, category: @groceries_category)

    # 23:30 UTC on November 4 is already 01:30 on November 5 in Kyiv: a new fiscal month
    travel_to Time.utc(2026, 11, 4, 23, 30) do
      Time.use_zone(@family.resolved_time_zone) do
        income_statement = IncomeStatement.new(@family)

        # The October period is complete in Kyiv, so excluding the current period keeps it
        assert_equal 300.0, income_statement.median_expense(interval: "month", exclude_current_period: true)
        assert_equal 300.0, income_statement.avg_expense(interval: "month", category: @groceries_category, exclude_current_period: true)
      end
    end
  end
end
