require "test_helper"

class BudgetCategoriesControllerTest < ActionDispatch::IntegrationTest
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
    BudgetCategory.any_instance.stubs(:update).returns(false)

    patch budget_budget_category_path(budget, budget_category), params: { budget_category: { budgeted_spending: 10 } }

    assert_response :unprocessable_entity
  end
end
