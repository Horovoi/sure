require "test_helper"

class BudgetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "budget_date_valid? allows going back 2 years even without entries" do
    two_years_ago = 2.years.ago.beginning_of_month
    assert Budget.budget_date_valid?(two_years_ago, family: @family)
  end

  test "budget_date_valid? allows going back to earliest entry date if more than 2 years ago" do
    # Create an entry 3 years ago
    old_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Old Account",
      status: "active",
      currency: "USD",
      balance: 1000
    )

    old_entry = Entry.create!(
      account: old_account,
      entryable: Transaction.new(category: categories(:income)),
      date: 3.years.ago,
      name: "Old Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should allow going back to the old entry date
    assert Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow dates before earliest entry or 2 years ago" do
    # Create an entry 1 year ago
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Test Account",
      status: "active",
      currency: "USD",
      balance: 500
    )

    Entry.create!(
      account: account,
      entryable: Transaction.new(category: categories(:income)),
      date: 1.year.ago,
      name: "Recent Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should not allow going back more than 2 years
    refute Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow future dates beyond current month" do
    refute Budget.budget_date_valid?(2.months.from_now, family: @family)
  end

  test "budget_date_valid? works with fiscal months enabled at 2-years boundary" do
    # Enable fiscal months with a start day that forces the back-one-month path for early month dates
    @family.use_fiscal_months = true
    @family.fiscal_month_start_day = 10

    # Using TimeWithZone here reproduces the original edge case
    two_years_ago = 2.years.ago.beginning_of_month
    assert Budget.budget_date_valid?(two_years_ago, family: @family)
  end

  test "budget_date_valid? allows going back to earliest entry > 2 years with fiscal months" do
    @family.use_fiscal_months = true
    @family.fiscal_month_start_day = 10

    # Create an entry over 3 years ago on an early day to exercise month subtraction
    old_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Very Old Account",
      status: "active",
      currency: "USD",
      balance: 100
    )

    Entry.create!(
      account: old_account,
      entryable: Transaction.new(category: categories(:income)),
      date: 3.years.ago.change(day: 5),
      name: "Very Old Transaction",
      amount: 10,
      currency: "USD"
    )

    assert Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "previous_budget_param returns nil when date is too old" do
    # Create a budget at the oldest allowed date
    two_years_ago = 2.years.ago.beginning_of_month
    budget = Budget.create!(
      family: @family,
      start_date: two_years_ago,
      end_date: two_years_ago.end_of_month,
      currency: "USD"
    )

    assert_nil budget.previous_budget_param
  end

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end

  test "viewing a budget keeps the amount of a category switched to income, hidden" do
    category = @family.categories.create!(name: "Side gig", classification: "expense", color: "#000000", lucide_icon: "briefcase")
    budget = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    budget.budget_categories.find_by!(category: category).update!(budgeted_spending: 300)

    category.update!(classification: "income")
    budget = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)

    assert_not_includes budget.budget_categories.map(&:category_id), category.id
    assert_equal 300, budget.all_budget_categories.find_by!(category: category).budgeted_spending

    category.update!(classification: "expense")
    budget = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)

    assert_equal 300, budget.budget_categories.find_by!(category: category).budgeted_spending
  end

  test "allocation_state names each stage of a budget" do
    category = @family.categories.create!(name: "Groceries", classification: "expense", color: "#000000", lucide_icon: "apple")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_category = budget.budget_categories.find_by!(category: category)

    budget_category.update!(budgeted_spending: 100)
    assert_equal :not_set_up, budget.reload.allocation_state
    assert_not budget.over_allocated?

    budget.update!(budgeted_spending: 100)
    assert_equal :fully_allocated, budget.reload.allocation_state
    assert budget.allocations_valid?

    budget.update!(budgeted_spending: 200)
    assert_equal :under_allocated, budget.reload.allocation_state

    budget.update!(budgeted_spending: 50)
    assert_equal :over_allocated, budget.reload.allocation_state
    assert_not budget.allocations_valid?

    budget_category.update!(budgeted_spending: 0)
    assert_equal :unallocated, budget.reload.allocation_state
  end

  test "income figures treat a missing expected income as zero" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 100, expected_income: nil)

    assert_equal 0, budget.actual_income_percent
    assert_equal(-budget.actual_income, budget.remaining_expected_income)
    assert_equal 0, budget.surplus_percent
  end

  test "a budget made before the fiscal start day changed is moved to the month's new period" do
    travel_to Date.new(2026, 3, 20) do
      budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 2, 1))
      budget.update!(budgeted_spending: 1234)
      assert_equal [ Date.new(2026, 2, 1), Date.new(2026, 2, 28) ], [ budget.start_date, budget.end_date ]

      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)
      found = Budget.find_or_bootstrap(@family, start_date: Budget.param_to_date("feb-2026", family: @family))

      assert_equal budget.id, found.id
      assert_equal [ Date.new(2026, 2, 10), Date.new(2026, 3, 9) ], [ found.start_date, found.end_date ]
      assert_equal 1234, found.budgeted_spending
      assert_equal "feb-2026", found.to_param
    end
  end

  test "a stranded budget is left alone when the new period is already taken" do
    travel_to Date.new(2026, 3, 20) do
      old = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 2, 1))
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)
      Budget.create!(family: @family, start_date: Date.new(2026, 2, 10), end_date: Date.new(2026, 3, 9), currency: "USD")

      found = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 2, 15))

      assert_not_equal old.id, found.id
      assert_equal Date.new(2026, 2, 1), old.reload.start_date
    end
  end
end
