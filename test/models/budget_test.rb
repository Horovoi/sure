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

  test "budget_date_valid? allows budgets up to two years ahead" do
    assert Budget.budget_date_valid?(2.months.from_now, family: @family)
    assert Budget.budget_date_valid?(Date.current.advance(years: 2), family: @family)
    refute Budget.budget_date_valid?(Date.current.advance(years: 2, months: 1), family: @family)
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

  # --- Refund netting ---------------------------------------------------------

  def budget_test_account
    @budget_test_account ||= Account.create!(
      family: @family, accountable: Depository.new, name: "Budget account",
      status: "active", currency: "USD", balance: 0
    )
  end

  def budget_test_entry(category:, amount:, name: "Entry")
    Entry.create!(
      account: budget_test_account, entryable: Transaction.new(category: category),
      date: Date.current, name: name, amount: amount, currency: "USD"
    )
  end

  def budget_test_category(name, classification: "expense", parent: nil)
    @family.categories.create!(name: name, classification: classification, parent: parent, color: "#000000", lucide_icon: "tag")
  end

  test "a refund lowers its category's spending and the total spending" do
    healthcare = budget_test_category("Healthcare")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: healthcare, amount: 500, name: "Doctor")
    budget_test_entry(category: healthcare, amount: -200, name: "Insurance refund")

    budget = Budget.find(budget.id)
    row = budget.budget_categories.find { |bc| bc.category_id == healthcare.id }

    assert_equal 300, budget.budget_category_actual_spending(row)
    assert_equal 300, budget.actual_spending
    assert_equal [ 300 ], budget.expense_category_totals.map(&:total)
  end

  test "a refund larger than its category's spending clamps the category at 0" do
    returns = budget_test_category("Returns")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: returns, amount: 50)
    budget_test_entry(category: returns, amount: -80)

    budget = Budget.find(budget.id)
    row = budget.budget_categories.find { |bc| bc.category_id == returns.id }

    assert_equal 0, budget.budget_category_actual_spending(row)
    assert_equal 0, budget.actual_spending
    assert_empty budget.expense_category_totals
  end

  test "a subcategory refund lowers the subcategory and its parent" do
    food = budget_test_category("Food")
    restaurants = budget_test_category("Restaurants", parent: food)
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: food, amount: 100)
    budget_test_entry(category: restaurants, amount: 300)
    budget_test_entry(category: restaurants, amount: -120)

    budget = Budget.find(budget.id)
    parent_row = budget.budget_categories.find { |bc| bc.category_id == food.id }
    sub_row = budget.budget_categories.find { |bc| bc.category_id == restaurants.id }

    assert_equal 180, budget.budget_category_actual_spending(sub_row)
    assert_equal 280, budget.budget_category_actual_spending(parent_row)
    assert_equal 280, budget.actual_spending
  end

  test "an uncategorized inflow does not lower uncategorized spending or the total spending" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: nil, amount: 400)
    budget_test_entry(category: nil, amount: -150)

    budget = Budget.find(budget.id)

    assert_equal 400, budget.budget_category_actual_spending(budget.uncategorized_budget_category)
    assert_equal 400, budget.actual_spending
    assert_equal 150, budget.actual_income
  end

  test "uncategorized and other investments keep separate totals" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: nil, amount: 75)

    budget = Budget.find(budget.id)
    keys = budget.send(:expense_totals_by_category).keys

    assert_includes keys, :uncategorized
    assert_includes keys, :other_investments
    assert_equal 75, budget.budget_category_actual_spending(budget.uncategorized_budget_category)
  end

  test "actual income leaves out the refunds of expense categories" do
    salary = budget_test_category("Salary", classification: "income")
    shopping = budget_test_category("Shopping")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_test_entry(category: salary, amount: -1000)
    budget_test_entry(category: shopping, amount: 200)
    budget_test_entry(category: shopping, amount: -50)

    budget = Budget.find(budget.id)

    assert_equal 1000, budget.actual_income
    assert_equal [ salary.id ], budget.income_category_totals.map { |ct| ct.category.id }
    assert_equal 100, budget.income_category_totals.first.weight
    assert_equal 150, budget.actual_spending
  end

  # --- Spending donut ---------------------------------------------------------

  test "the donut leaves out subcategory rows" do
    food = budget_test_category("Food")
    restaurants = budget_test_category("Restaurants", parent: food)
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 1000)
    budget.budget_categories.find_by!(category: food).update!(budgeted_spending: 500)
    budget_test_entry(category: restaurants, amount: 120)

    budget = Budget.find(budget.id)
    food_row = budget.budget_categories.find { |bc| bc.category_id == food.id }
    sub_row = budget.budget_categories.find { |bc| bc.category_id == restaurants.id }
    segments = budget.to_donut_segments_json

    assert_includes segments.map { |s| s[:id] }, food_row.id
    assert_not_includes segments.map { |s| s[:id] }, sub_row.id
    assert_equal 120, segments.find { |s| s[:id] == food_row.id }[:amount]
  end

  test "the donut adds an uncategorized segment when something was spent without a category" do
    food = budget_test_category("Food")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 1000)
    budget.budget_categories.find_by!(category: food).update!(budgeted_spending: 500)

    uncategorized_id = BudgetCategory.uncategorized.id
    assert_not_includes Budget.find(budget.id).to_donut_segments_json.map { |s| s[:id] }, uncategorized_id

    budget_test_entry(category: nil, amount: 60)
    budget = Budget.find(budget.id)
    segment = budget.to_donut_segments_json.find { |s| s[:id] == uncategorized_id }

    assert_equal 60, segment[:amount]
    assert_includes budget.donut_budget_categories.map(&:id), uncategorized_id
  end

  test "a budget with only a total shows its category segments, not one grey segment" do
    food = budget_test_category("Food")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 1000)
    budget_test_entry(category: food, amount: 100)

    budget = Budget.find(budget.id)
    assert_equal :unallocated, budget.allocation_state

    segments = budget.to_donut_segments_json
    food_row = budget.budget_categories.find { |bc| bc.category_id == food.id }

    assert_equal 100, segments.find { |s| s[:id] == food_row.id }[:amount]
    assert_equal 900, segments.find { |s| s[:id] == "unused" }[:amount]
  end

  test "a budget without an amount shows one grey segment" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)

    assert_equal [ { color: "var(--budget-unallocated-fill)", amount: 1, id: "unused" } ], budget.to_donut_segments_json
  end

  # --- Copy a previous budget -------------------------------------------------

  test "copy_from! copies the totals and the category amounts" do
    food = budget_test_category("Food")
    source = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    source.update!(budgeted_spending: 3000, expected_income: 4000)
    source.budget_categories.find_by!(category: food).update!(budgeted_spending: 500)
    target = Budget.find_or_bootstrap(@family, start_date: Date.current)

    target.copy_from!(source)
    target.reload

    assert_equal 3000, target.budgeted_spending
    assert_equal 4000, target.expected_income
    assert_equal 500, target.budget_categories.find_by!(category: food).budgeted_spending
  end

  test "copy_from! leaves the hidden rows of categories that are now income alone" do
    side_gig = budget_test_category("Side gig")
    source = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    source.update!(budgeted_spending: 1000)
    source.budget_categories.find_by!(category: side_gig).update!(budgeted_spending: 300)
    target = Budget.find_or_bootstrap(@family, start_date: Date.current)
    target.budget_categories.find_by!(category: side_gig).update!(budgeted_spending: 50)

    side_gig.update!(classification: "income")
    Budget.find(target.id).copy_from!(Budget.find(source.id))

    assert_equal 50, target.all_budget_categories.find_by!(category: side_gig).budgeted_spending
  end

  test "copy_from! refuses a budget of another family or one that does not come first" do
    target = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    later = Budget.create!(family: @family, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, currency: "USD", budgeted_spending: 100)
    other_family = Budget.create!(family: families(:dylan_family), start_date: 3.months.ago.beginning_of_month, end_date: 3.months.ago.end_of_month, currency: "USD", budgeted_spending: 100)

    assert_raises(ArgumentError) { target.copy_from!(other_family) }
    assert_raises(ArgumentError) { target.copy_from!(later) }
    assert_nil target.reload.budgeted_spending
  end

  test "copy_from! keeps the source amounts of a parent and its subcategory" do
    food = budget_test_category("Food")
    restaurants = budget_test_category("Restaurants", parent: food)
    source = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    source.update!(budgeted_spending: 1000)
    source.budget_categories.find_by!(category: food).update!(budgeted_spending: 500)
    source.budget_categories.find_by!(category: restaurants).update!(budgeted_spending: 200)
    target = Budget.find_or_bootstrap(@family, start_date: Date.current)

    target.copy_from!(source)
    target = Budget.find(target.id)

    assert_equal 500, target.budget_categories.find_by!(category: food).budgeted_spending
    assert_equal 200, target.budget_categories.find_by!(category: restaurants).budgeted_spending
    assert_equal 500, target.allocated_spending
  end

  test "most_recent_initialized_budget is the newest earlier budget that is set up" do
    older = Budget.find_or_bootstrap(@family, start_date: 3.months.ago)
    older.update!(budgeted_spending: 100)
    newer = Budget.find_or_bootstrap(@family, start_date: 2.months.ago)
    newer.update!(budgeted_spending: 200)
    Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    target = Budget.find_or_bootstrap(@family, start_date: Date.current)

    assert_equal newer, target.most_recent_initialized_budget
    assert_nil older.most_recent_initialized_budget
  end

  # --- Budgets ahead ----------------------------------------------------------

  test "with fiscal start day 31 a budget is valid 24 periods ahead and not one period later" do
    travel_to Date.new(2026, 11, 15) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)

      assert Budget.budget_date_valid?(Budget.param_to_date("oct-2028", family: @family), family: @family)
      assert Budget.budget_date_valid?(Budget.param_to_date("feb-2028", family: @family), family: @family)
      refute Budget.budget_date_valid?(Budget.param_to_date("nov-2028", family: @family), family: @family)
    end
  end

  test "next_budget_param of the current budget is the next month" do
    travel_to Date.new(2026, 11, 15) do
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)

      assert budget.current?
      assert_equal "dec-2026", budget.next_budget_param
    end
  end

  test "with fiscal start day 31 the neighbours step one period through February" do
    travel_to Date.new(2026, 11, 15) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)

      january = Budget.find_or_bootstrap(@family, start_date: Budget.param_to_date("jan-2027", family: @family))
      assert_equal [ Date.new(2027, 1, 31), Date.new(2027, 2, 27) ], [ january.start_date, january.end_date ]
      assert_equal "feb-2027", january.next_budget_param

      february = Budget.find_or_bootstrap(@family, start_date: Budget.param_to_date("feb-2027", family: @family))
      assert_equal [ Date.new(2027, 2, 28), Date.new(2027, 3, 30) ], [ february.start_date, february.end_date ]
      assert_equal "mar-2027", february.next_budget_param
      assert_equal "jan-2027", february.previous_budget_param

      current = Budget.find_or_bootstrap(@family, start_date: Date.current)
      assert_equal [ Date.new(2026, 10, 31), Date.new(2026, 11, 29) ], [ current.start_date, current.end_date ]
      assert_equal "nov-2026", current.next_budget_param
    end
  end

  test "a budget saved with a wrong end date for fiscal start day 31 gets the right one" do
    travel_to Date.new(2026, 11, 15) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)
      saved = Budget.create!(family: @family, start_date: Date.new(2026, 10, 31), end_date: Date.new(2026, 10, 30), currency: "USD", budgeted_spending: 100)

      found = Budget.find_or_bootstrap(@family, start_date: Date.current)

      assert_equal saved.id, found.id
      assert_equal Date.new(2026, 11, 29), found.end_date
    end
  end

  test "a future month starts as an empty budget" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.advance(months: 13))

    assert budget.persisted?
    assert_not budget.initialized?
  end

  # w2-transfers transfer-fees
  test "a transfer fee counts as spending in the budget's Fees category" do
    checking = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 1_000, accountable: Depository.new)
    savings = @family.accounts.create!(name: "Savings", currency: @family.currency, balance: 0, accountable: Depository.new)
    fees_category = Transfer.fees_category_for(@family)

    Transfer::Creator.new(
      family: @family, source_account_id: checking.id, destination_account_id: savings.id,
      date: Date.current, amount: 500, source_fee: "12"
    ).create

    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget_category = budget.budget_categories.find_by!(category: fees_category)

    assert_equal 12, budget.budget_category_actual_spending(budget_category)
    assert_equal 12, budget.actual_spending
  end
end
