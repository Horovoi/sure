require "test_helper"

class BudgetCategoriesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "the categories step of a month never visited, before setup, goes to the setup step" do
    month = 2.months.ago.to_date
    param = Budget.date_to_param(month, family: @family)
    assert_nil @family.budgets.find_by(start_date: month.beginning_of_month)

    get budget_budget_categories_path(param)

    budget = @family.budgets.find_by!(start_date: month.beginning_of_month)
    assert_redirected_to edit_budget_path(budget)
  end

  test "the categories step of a month outside the budget range is not found" do
    get budget_budget_categories_path(Budget.date_to_param(3.months.from_now, family: @family))

    assert_response :not_found
  end

  test "the categories step renders for a set-up budget" do
    get budget_budget_categories_path(budgets(:one))

    assert_response :ok
  end

  test "a category update only reaches categories of the budget in the URL" do
    budget = budgets(:one)
    other = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    other_category = other.budget_categories.first

    patch budget_budget_category_path(budget, other_category), params: { budget_category: { budgeted_spending: 10 } }

    assert_response :not_found
    assert_equal 0, other_category.reload.budgeted_spending
  end

  test "a failed category update renders the step again" do
    budget = budgets(:one)
    Budget.find_or_bootstrap(@family, start_date: budget.start_date)
    budget_category = budget.reload.budget_categories.first

    patch budget_budget_category_path(budget, budget_category), params: { budget_category: { budgeted_spending: -10 } }

    assert_response :unprocessable_entity
    assert_equal 0, budget_category.reload.budgeted_spending
  end

  test "the drilldown leaves out funds movements and card payments and still lists loan payments" do
    budget = budgets(:one)
    # Large amounts on today, so they sort first among the three rows the drilldown shows
    create_transaction(account: accounts(:depository), date: Date.current, amount: 9_300, name: "DRILLDOWN_CC_PAYMENT", kind: "cc_payment")
    create_transaction(account: accounts(:credit_card), date: Date.current, amount: -9_200, name: "DRILLDOWN_FUNDS_MOVEMENT", kind: "funds_movement")
    create_transaction(account: accounts(:depository), date: Date.current, amount: 9_100, name: "DRILLDOWN_ONE_TIME", kind: "one_time")
    create_transaction(account: accounts(:depository), date: Date.current, amount: 9_000, name: "DRILLDOWN_LOAN_PAYMENT", kind: "loan_payment")

    get budget_budget_category_path(budget, BudgetCategory.uncategorized.id)

    assert_response :success
    assert_no_match "DRILLDOWN_CC_PAYMENT", response.body
    assert_no_match "DRILLDOWN_FUNDS_MOVEMENT", response.body
    assert_no_match "DRILLDOWN_ONE_TIME", response.body
    assert_match "DRILLDOWN_LOAN_PAYMENT", response.body
  end

  test "Confirm is enabled for a budget with only a total" do
    budget = budgets(:one)
    Budget.find_or_bootstrap(@family, start_date: budget.start_date)
    budget.reload.all_budget_categories.update_all(budgeted_spending: 0)

    get budget_budget_categories_path(budget)

    assert_response :ok
    assert_select "##{dom_id(budget, :confirm_button)} button"
    assert_select "##{dom_id(budget, :confirm_button)} button[disabled]", count: 0
  end

  test "Confirm is disabled when the categories add up to more than the total" do
    budget = budgets(:one)
    Budget.find_or_bootstrap(@family, start_date: budget.start_date)
    budget.reload
    budget.budget_categories.reject(&:subcategory?).first.update!(budgeted_spending: budget.budgeted_spending + 1)

    get budget_budget_categories_path(budget)

    assert_response :ok
    assert_select "##{dom_id(budget, :confirm_button)} button[disabled]"
  end

  # w3-envelope envelope-budgeting
  test "a subcategory update raises its parent and streams the parent's row" do
    budget = budgets(:one)
    Budget.find_or_bootstrap(@family, start_date: budget.start_date)
    budget.reload
    parent = budget.budget_categories.find_by!(category: categories(:food_and_drink))
    child = budget.budget_categories.find_by!(category: categories(:subcategory))
    parent.update!(budgeted_spending: 500)

    patch budget_budget_category_path(budget, child), params: { budget_category: { budgeted_spending: 120 } }, as: :turbo_stream

    assert_response :success
    assert_equal 620, parent.reload.budgeted_spending
    assert_includes response.body, dom_id(parent, :form)
    fragment = Nokogiri::HTML.fragment(response.body)
    assert_equal 620, fragment.at_css("input##{dom_id(parent, :budgeted_spending)}")["value"].to_d
    assert_nil fragment.at_css("input##{dom_id(parent, :budgeted_spending)}")["max"]
  end

  test "a parent update below its subcategories stores and streams their sum" do
    budget = budgets(:one)
    Budget.find_or_bootstrap(@family, start_date: budget.start_date)
    budget.reload
    parent = budget.budget_categories.find_by!(category: categories(:food_and_drink))
    child = budget.budget_categories.find_by!(category: categories(:subcategory))
    child.update_budgeted_spending!(300)

    patch budget_budget_category_path(budget, parent), params: { budget_category: { budgeted_spending: 100 } }, as: :turbo_stream

    assert_response :success
    assert_equal 300, parent.reload.budgeted_spending
    fragment = Nokogiri::HTML.fragment(response.body)
    assert_equal 300, fragment.at_css("input##{dom_id(parent, :budgeted_spending)}")["value"].to_d
  end
end
