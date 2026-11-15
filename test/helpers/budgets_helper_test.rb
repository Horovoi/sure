require "test_helper"

class BudgetsHelperTest < ActionView::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)

    @parent_category = helper_test_category("Helper Parent")
    @child_category = helper_test_category("Helper Child", parent: @parent_category)

    @parent_budget_category = BudgetCategory.create!(budget: @budget, category: @parent_category, budgeted_spending: 200, currency: "USD")
    @child_budget_category = BudgetCategory.create!(budget: @budget, category: @child_category, budgeted_spending: 0, currency: "USD")
  end

  def helper_test_category(name, parent: nil)
    @family.categories.create!(
      name: "#{name} #{SecureRandom.hex(4)}", parent: parent, classification: "expense",
      color: "#4da568", lucide_icon: "utensils"
    )
  end

  def helper_test_entry(category:, amount:, name: "Helper spending")
    Entry.create!(
      account: accounts(:depository), entryable: Transaction.create!(category: category),
      date: Date.current, name: name, amount: amount, currency: "USD"
    )
  end

  test "hides inheriting subcategory with no budget and no spending from on-track section" do
    state = budget_categories_view_state(@budget)
    group = state[:on_track_groups].find { |g| g.budget_category.id == @parent_budget_category.id }

    assert group.present?
    assert_empty group.budget_subcategories
  end

  test "shows inheriting subcategory in on-track section when it has spending" do
    helper_test_entry(category: @child_category, amount: 25)

    state = budget_categories_view_state(Budget.find(@budget.id))
    group = state[:on_track_groups].find { |g| g.budget_category.category_id == @parent_category.id }

    assert group.present?
    assert_includes group.budget_subcategories.map(&:category_id), @child_category.id
  end

  test "keeps group when only subcategory is over budget" do
    parent = helper_test_category("Helper Group Parent")
    child = helper_test_category("Helper Group Child", parent: parent)
    BudgetCategory.create!(budget: @budget, category: parent, budgeted_spending: 300, currency: "USD")
    BudgetCategory.create!(budget: @budget, category: child, budgeted_spending: 50, currency: "USD")
    helper_test_entry(category: child, amount: 100)

    state = budget_categories_view_state(Budget.find(@budget.id))
    group = state[:over_budget_groups].find { |g| g.budget_category.category_id == parent.id }

    assert group.present?
    refute group.budget_category.any_over_budget?
    assert_equal [ child.id ], group.budget_subcategories.map(&:category_id)
    assert group.budget_subcategories.first.any_over_budget?
  end

  test "a filtered group's other spending still subtracts the hidden subcategories" do
    limited_child = helper_test_category("Helper Limited Child", parent: @parent_category)
    BudgetCategory.create!(budget: @budget, category: limited_child, budgeted_spending: 10, currency: "USD")
    helper_test_entry(category: @parent_category, amount: 30, name: "Direct parent spending")
    helper_test_entry(category: limited_child, amount: 15, name: "Overspent child")

    state = budget_categories_view_state(Budget.find(@budget.id))
    on_track_group = state[:on_track_groups].find { |g| g.budget_category.category_id == @parent_category.id }
    over_budget_group = state[:over_budget_groups].find { |g| g.budget_category.category_id == @parent_category.id }

    # The overspent child moves to Over budget; the parent stays on track with its own 30 as "Other".
    assert_empty on_track_group.budget_subcategories
    assert_equal [ limited_child.id ], over_budget_group.budget_subcategories.map(&:category_id)
    assert_equal 30, on_track_group.other_spending
  end

  test "counts the over budget and on track rows" do
    helper_test_entry(category: @parent_category, amount: 500)

    state = budget_categories_view_state(Budget.find(@budget.id))

    assert state[:over_budget_groups].any? { |g| g.budget_category.category_id == @parent_category.id }
    refute state[:on_track_groups].any? { |g| g.budget_category.category_id == @parent_category.id }
    assert_operator state[:over_budget_count], :>=, 1
  end

  test "uncategorized spending past what is left to allocate counts as over budget" do
    @budget.update!(budgeted_spending: @budget.allocated_spending)
    helper_test_entry(category: nil, amount: 75, name: "Uncategorized spending")

    budget = Budget.find(@budget.id)
    state = budget_categories_view_state(budget)

    assert budget_has_over_budget?(budget)
    assert state[:show_over_budget_uncategorized]
    refute state[:show_on_track_uncategorized]
  end

  test "uncategorized spending within what is left to allocate is on track" do
    @budget.update!(budgeted_spending: @budget.allocated_spending + 1000)
    helper_test_entry(category: nil, amount: 75, name: "Uncategorized spending")

    budget = Budget.find(@budget.id)
    state = budget_categories_view_state(budget)

    refute state[:show_over_budget_uncategorized]
    assert state[:show_on_track_uncategorized]
  end

  test "a budget that is not set up has no over budget rows and lists every group" do
    @budget.update!(budgeted_spending: nil)
    budget = Budget.find(@budget.id)

    state = budget_categories_view_state(budget)

    refute budget_has_over_budget?(budget)
    assert_empty state[:over_budget_groups]
    assert state[:on_track_groups].any? { |g| g.budget_category.category_id == @parent_category.id }
  end

  test "current_budget_filter falls back to all for an unknown filter" do
    controller.params = ActionController::Parameters.new(filter: "on_track")
    assert_equal "on_track", current_budget_filter

    controller.params = ActionController::Parameters.new(filter: "bogus")
    assert_equal "all", current_budget_filter
  end
end
