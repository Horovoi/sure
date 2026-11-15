require "test_helper"

class BudgetCategoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)

    # Create parent category with unique name
    @parent_category = Category.create!(
      name: "Test Food & Groceries #{Time.now.to_f}",
      family: @family,
      color: "#4da568",
      lucide_icon: "utensils",
      classification: "expense"
    )

    # Create subcategories with unique names
    @subcategory_with_limit = Category.create!(
      name: "Test Restaurants #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    @subcategory_inheriting = Category.create!(
      name: "Test Groceries #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    # Create budget categories
    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 1000,
      currency: "USD"
    )

    @subcategory_with_limit_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_with_limit,
      budgeted_spending: 300,
      currency: "USD"
    )

    @subcategory_inheriting_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_inheriting,
      budgeted_spending: 0,  # Inherits from parent
      currency: "USD"
    )
  end

  test "subcategory with zero budget inherits from parent" do
    assert @subcategory_inheriting_bc.inherits_parent_budget?
    refute @subcategory_with_limit_bc.inherits_parent_budget?
    refute @parent_budget_category.inherits_parent_budget?
  end

  test "parent_budget_category returns parent for subcategories" do
    assert_equal @parent_budget_category, @subcategory_inheriting_bc.parent_budget_category
    assert_equal @parent_budget_category, @subcategory_with_limit_bc.parent_budget_category
    assert_nil @parent_budget_category.parent_budget_category
  end

  test "display_budgeted_spending shows parent budget for inheriting subcategories" do
    assert_equal 1000, @subcategory_inheriting_bc.display_budgeted_spending
    assert_equal 300, @subcategory_with_limit_bc.display_budgeted_spending
    assert_equal 1000, @parent_budget_category.display_budgeted_spending
  end

  test "inheriting subcategory shares parent available_to_spend" do
    # Mock the actual spending values
    # Parent's actual_spending from income_statement includes all children
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(150)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(50)

    # Parent available calculation:
    # shared_pool = 1000 (parent budget) - 300 (subcategory with limit budget) = 700
    # shared_pool_spending = 150 (total) - 100 (subcategory with limit spending) = 50
    # available = 700 - 50 = 650
    assert_equal 650, @parent_budget_category.available_to_spend

    # Inheriting subcategory shares parent's available (650)
    assert_equal 650, @subcategory_inheriting_bc.available_to_spend

    # Subcategory with limit: 300 (its budget) - 100 (its spending) = 200
    assert_equal 200, @subcategory_with_limit_bc.available_to_spend
  end

  test "max_allocation excludes budgets of inheriting siblings" do
    # Create another inheriting subcategory
    another_inheriting = Category.create!(
      name: "Test Coffee #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    another_inheriting_bc = BudgetCategory.create!(
      budget: @budget,
      category: another_inheriting,
      budgeted_spending: 0,  # Inherits
      currency: "USD"
    )

    # Max allocation for new subcategory should only account for the one with explicit limit (300)
    # 1000 (parent) - 300 (subcategory_with_limit) = 700
    assert_equal 700, another_inheriting_bc.max_allocation

    # If we add a new subcategory with a limit
    new_subcategory_cat = Category.create!(
      name: "Test Fast Food #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    new_subcategory_bc = BudgetCategory.create!(
      budget: @budget,
      category: new_subcategory_cat,
      budgeted_spending: 0,
      currency: "USD"
    )

    # Max should still be 700 because both inheriting subcategories don't count
    assert_equal 700, new_subcategory_bc.max_allocation
  end

  test "percent_of_budget_spent for inheriting subcategory uses parent budget" do
    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # 100 / 1000 (parent budget) = 10%
    assert_equal 10.0, @subcategory_inheriting_bc.percent_of_budget_spent
  end

  test "parent with no subcategories works as before" do
    # Create a standalone parent category without subcategories
    standalone_category = Category.create!(
      name: "Test Entertainment #{Time.now.to_f}",
      family: @family,
      color: "#a855f7",
      lucide_icon: "drama",
      classification: "expense"
    )

    standalone_bc = BudgetCategory.create!(
      budget: @budget,
      category: standalone_category,
      budgeted_spending: 500,
      currency: "USD"
    )

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(standalone_bc).returns(200)

    # Should work exactly as before: 500 - 200 = 300
    assert_equal 300, standalone_bc.available_to_spend
    assert_equal 40.0, standalone_bc.percent_of_budget_spent
  end

  test "group other_spending returns direct parent spending when subcategories exist" do
    # Mock spending: parent=500 total, subcategories=100+150=250, so direct=250
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(500)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(150)

    group = BudgetCategory::Group.new(@parent_budget_category, [ @subcategory_with_limit_bc, @subcategory_inheriting_bc ])
    assert_equal 250, group.other_spending
  end

  test "group other_spending returns zero when no subcategories" do
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(500)

    group = BudgetCategory::Group.new(@parent_budget_category, [])
    assert_equal 0, group.other_spending
  end

  test "group other_spending returns zero when subcategories account for all spending" do
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(250)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(150)

    group = BudgetCategory::Group.new(@parent_budget_category, [ @subcategory_with_limit_bc, @subcategory_inheriting_bc ])
    assert_equal 0, group.other_spending
  end

  test "parent with only inheriting subcategories shares entire budget" do
    # Set subcategory_with_limit to also inherit
    @subcategory_with_limit_bc.update!(budgeted_spending: 0)

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(200)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # All should show same available: 1000 - 200 = 800
    assert_equal 800, @parent_budget_category.available_to_spend
    assert_equal 800, @subcategory_with_limit_bc.available_to_spend
    assert_equal 800, @subcategory_inheriting_bc.available_to_spend
  end

  test "the uncategorized row has no subcategories" do
    assert_equal [], @budget.uncategorized_budget_category.subcategories
  end

  test "the uncategorized row can spend what is left to allocate, less uncategorized spending" do
    @budget.stubs(:budget_category_actual_spending).returns(100)
    @budget.stubs(:budget_category_actual_spending).with { |bc| bc.category_id.nil? }.returns(40)

    uncategorized = @budget.uncategorized_budget_category

    assert_equal [ @budget.available_to_allocate, 0 ].max - 40, uncategorized.available_to_spend
  end

  test "budgeted? is true only when the displayed budget is positive" do
    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(100)
    assert @subcategory_with_limit_bc.budgeted?

    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(0)
    refute @subcategory_with_limit_bc.budgeted?

    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(nil)
    refute @subcategory_with_limit_bc.budgeted?
  end

  test "unbudgeted_with_spending? is true only with spending and no budget" do
    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:actual_spending).returns(10)
    assert @subcategory_with_limit_bc.unbudgeted_with_spending?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(true)
    refute @subcategory_with_limit_bc.unbudgeted_with_spending?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:actual_spending).returns(0)
    refute @subcategory_with_limit_bc.unbudgeted_with_spending?
  end

  test "on_track? and over_budget_with_budget? split the budgeted rows" do
    @subcategory_with_limit_bc.stubs(:budgeted?).returns(true)
    @subcategory_with_limit_bc.stubs(:over_budget?).returns(false)
    assert @subcategory_with_limit_bc.on_track?
    refute @subcategory_with_limit_bc.over_budget_with_budget?

    @subcategory_with_limit_bc.stubs(:over_budget?).returns(true)
    refute @subcategory_with_limit_bc.on_track?
    assert @subcategory_with_limit_bc.over_budget_with_budget?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    refute @subcategory_with_limit_bc.on_track?
    refute @subcategory_with_limit_bc.over_budget_with_budget?
  end

  test "a near-limit row is on track" do
    @budget.stubs(:budget_category_actual_spending).returns(0)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(290)

    assert @subcategory_with_limit_bc.near_limit?
    assert @subcategory_with_limit_bc.on_track?
    refute @subcategory_with_limit_bc.any_over_budget?
  end

  test "any_over_budget? is true for a parent whose shared subcategory overspends it" do
    # Parent 1000 with 300 ring-fenced: the shared pool is 700, and the inheriting child spent 1000 of it.
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(1100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(1000)

    assert @parent_budget_category.any_over_budget?
    assert @subcategory_inheriting_bc.any_over_budget?
    refute @subcategory_with_limit_bc.any_over_budget?
  end

  test "visible_on_track? hides an inheriting subcategory until it has spending" do
    @subcategory_with_limit_bc.stubs(:on_track?).returns(false)
    refute @subcategory_with_limit_bc.visible_on_track?

    @parent_budget_category.stubs(:on_track?).returns(true)
    assert @parent_budget_category.visible_on_track?

    @subcategory_inheriting_bc.stubs(:on_track?).returns(true)
    @subcategory_inheriting_bc.stubs(:actual_spending).returns(0)
    refute @subcategory_inheriting_bc.visible_on_track?

    @subcategory_inheriting_bc.stubs(:actual_spending).returns(10)
    assert @subcategory_inheriting_bc.visible_on_track?
  end

  test "group other_spending uses every subcategory when the shown ones are filtered" do
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(500)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(150)

    group = BudgetCategory::Group.new(
      @parent_budget_category, [ @subcategory_with_limit_bc ],
      all_subcategories: [ @subcategory_with_limit_bc, @subcategory_inheriting_bc ]
    )
    assert_equal 250, group.other_spending
  end

  # ===========================================================================
  # Subscription reservations
  # ===========================================================================

  test "a monthly subscription due later in the period is reserved once" do
    travel_to Date.new(2030, 3, 3) do
      budget, bc = reservation_budget
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 15)

      assert_equal Money.new(15, "USD"), bc.subscriptions_reserved
      assert_equal Money.new(15, "USD"), budget.subscriptions_reserved
      assert_equal 0, bc.subscriptions_reserved_unconvertible_count
    end
  end

  test "a generated charge leaves nothing reserved" do
    travel_to Date.new(2030, 3, 25) do
      _budget, bc = reservation_budget
      # generate_transaction! moved the row to the next period
      row = reservation_row(next_expected_date: Date.new(2030, 4, 20), last_occurrence_date: Date.new(2030, 3, 20))
      reservation_charge(row, Date.new(2030, 3, 20))

      assert_equal Money.new(0, "USD"), bc.subscriptions_reserved
      refute bc.subscriptions_reserved?
    end
  end

  test "a yearly subscription outside the period is not reserved" do
    travel_to Date.new(2030, 3, 3) do
      _budget, bc = reservation_budget
      reservation_row(
        manual: false, subscription_state: "subscription", billing_cycle: "yearly",
        expected_month: 8, next_expected_date: Date.new(2030, 8, 20), amount: 120
      )

      assert_equal Money.new(0, "USD"), bc.subscriptions_reserved
    end
  end

  test "a yearly subscription due in the period is reserved once" do
    travel_to Date.new(2030, 3, 3) do
      _budget, bc = reservation_budget
      reservation_row(
        manual: false, subscription_state: "subscription", billing_cycle: "yearly",
        expected_month: 3, next_expected_date: Date.new(2030, 3, 20), amount: 120
      )

      assert_equal Money.new(120, "USD"), bc.subscriptions_reserved
    end
  end

  test "reservations follow the fiscal month boundaries" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)

    travel_to Date.new(2030, 3, 11) do
      _budget, bc = reservation_budget(start_date: Date.new(2030, 3, 10), end_date: Date.new(2030, 4, 9))
      reservation_row(expected_day_of_month: 15, next_expected_date: Date.new(2030, 3, 15), amount: 10)
      reservation_row(expected_day_of_month: 9, next_expected_date: Date.new(2030, 4, 9), amount: 20)
      reservation_row(expected_day_of_month: 10, next_expected_date: Date.new(2030, 4, 10), amount: 40)

      assert_equal Money.new(30, "USD"), bc.subscriptions_reserved
    end
  end

  test "a USD subscription in a UAH family is converted at the nearest rate" do
    @family.update!(currency: "UAH")

    travel_to Date.new(2030, 3, 3) do
      ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2030, 3, 1), rate: 41.5)
      _budget, bc = reservation_budget(currency: "UAH")
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 10, currency: "USD")

      assert_equal Money.new(415, "UAH"), bc.subscriptions_reserved
      assert_equal 0, bc.subscriptions_reserved_unconvertible_count
    end
  end

  test "a subscription in a currency with no rate is counted, never converted at 1" do
    ExchangeRate.stubs(:provider).returns(nil)

    travel_to Date.new(2030, 3, 3) do
      budget, bc = reservation_budget
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 10, currency: "EUR")
      reservation_row(next_expected_date: Date.new(2030, 3, 21), amount: 7, currency: "USD")

      assert_equal Money.new(7, "USD"), bc.subscriptions_reserved
      assert_equal 1, bc.subscriptions_reserved_unconvertible_count
      assert_equal 1, budget.subscriptions_reserved_unconvertible_count
      assert bc.subscriptions_reserved?
    end
  end

  test "inactive, dismissed, income and uncategorized rows are not reserved" do
    travel_to Date.new(2030, 3, 3) do
      budget, bc = reservation_budget
      date = Date.new(2030, 3, 20)
      reservation_row(next_expected_date: date, status: "inactive", inactive_reason: "user")
      reservation_row(next_expected_date: date, manual: false, subscription_state: "dismissed", dismissed_at: 1.day.ago)
      reservation_row(next_expected_date: date, manual: false, subscription_state: "pattern")
      reservation_row(next_expected_date: date, amount: -100)
      reservation_row(next_expected_date: date, category: nil)

      assert_equal Money.new(0, "USD"), bc.subscriptions_reserved
      assert_equal Money.new(0, "USD"), budget.subscriptions_reserved
      assert_empty budget.subscription_reservations_by_category_id
    end
  end

  test "a linked charge within 5 days removes that date" do
    travel_to Date.new(2030, 3, 3) do
      _budget, bc = reservation_budget
      near = reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 10)
      reservation_charge(near, Date.new(2030, 3, 15), source: nil)
      far = reservation_row(next_expected_date: Date.new(2030, 3, 22), amount: 20)
      reservation_charge(far, Date.new(2030, 3, 16), source: nil)

      assert_equal Money.new(20, "USD"), bc.subscriptions_reserved
    end
  end

  test "a parent sums its subcategories" do
    travel_to Date.new(2030, 3, 3) do
      budget, parent_bc = reservation_budget
      sub_bc = budget.budget_categories.find { |row| row.category_id == @subcategory_with_limit.id }
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 10)
      reservation_row(next_expected_date: Date.new(2030, 3, 21), amount: 5, category: @subcategory_with_limit)

      assert_equal Money.new(15, "USD"), parent_bc.subscriptions_reserved
      assert_equal Money.new(5, "USD"), sub_bc.subscriptions_reserved
      assert_equal Money.new(15, "USD"), budget.subscriptions_reserved
    end
  end

  test "a past budget reserves nothing" do
    travel_to Date.new(2030, 3, 3) do
      _budget, bc = reservation_budget(start_date: Date.new(2030, 2, 1), end_date: Date.new(2030, 2, 28))
      reservation_row(next_expected_date: Date.new(2030, 2, 20), amount: 10)

      assert_equal Money.new(0, "USD"), bc.subscriptions_reserved
    end
  end

  test "reservations do not change spent, available or allocation figures" do
    travel_to Date.new(2030, 3, 3) do
      budget, bc = reservation_budget
      before = [ bc.actual_spending, bc.available_to_spend, budget.allocated_spending, budget.available_to_spend ]
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 300)

      budget = Budget.find(budget.id)
      bc = budget.budget_categories.find { |row| row.category_id == @parent_category.id }
      assert_equal before, [ bc.actual_spending, bc.available_to_spend, budget.allocated_spending, budget.available_to_spend ]
      assert_equal Money.new(300, "USD"), bc.subscriptions_reserved
    end
  end

  test "reservations load once per budget" do
    travel_to Date.new(2030, 3, 3) do
      budget, _bc = reservation_budget
      reservation_row(next_expected_date: Date.new(2030, 3, 20), amount: 10)
      reservation_row(next_expected_date: Date.new(2030, 3, 21), amount: 5, category: @subcategory_with_limit)

      budget = Budget.find(budget.id)
      budget.family
      budget.budget_categories.load

      # The recurring rows and their linked charges, one query each
      assert_queries_count(2) do
        budget.budget_categories.each(&:subscriptions_reserved)
        budget.subscriptions_reserved
      end

      assert_no_queries { budget.subscription_reservations_by_category_id }
    end
  end

  private
    # A budget of the dylan family (currency USD unless changed) for March 2030 by
    # default, with rows for the test categories. Returns it and the parent row.
    def reservation_budget(start_date: Date.new(2030, 3, 1), end_date: Date.new(2030, 3, 31), currency: "USD")
      budget = Budget.create!(family: @family, start_date: start_date, end_date: end_date, currency: currency,
                              budgeted_spending: 1000, expected_income: 1000)
      [ @parent_category, @subcategory_with_limit, @subcategory_inheriting ].each do |category|
        BudgetCategory.create!(budget: budget, category: category, budgeted_spending: category == @parent_category ? 500 : 0, currency: currency)
      end

      budget = Budget.find(budget.id)
      [ budget, budget.budget_categories.find { |row| row.category_id == @parent_category.id } ]
    end

    def reservation_row(**attributes)
      RecurringTransaction.create!({
        family: @family,
        name: "Streaming #{SecureRandom.hex(4)}",
        amount: 10,
        currency: "USD",
        expected_day_of_month: attributes[:next_expected_date]&.day || 20,
        last_occurrence_date: Date.new(2030, 2, 20),
        next_expected_date: Date.new(2030, 3, 20),
        status: "active",
        manual: true,
        category: @parent_category
      }.merge(attributes))
    end

    def reservation_charge(row, date, source: "subscription")
      Entry.create!(
        account: accounts(:depository), date: date, name: row.name, amount: row.amount, currency: "USD", source: source,
        entryable: Transaction.new(category: row.category, recurring_transaction: row)
      )
    end
end
