require "test_helper"

class BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @budget = budgets(:one)
  end

  test "a blank expected income is saved as zero and the budget page renders" do
    patch budget_path(@budget), params: { budget: { budgeted_spending: 4000, expected_income: "" } }

    assert_redirected_to budget_budget_categories_path(@budget)
    assert_equal 0, @budget.reload.expected_income

    get budget_path(@budget)
    assert_response :ok
  end

  test "a fully allocated budget keeps the Budgeted tab" do
    @budget.update!(budgeted_spending: 500)
    Budget.find_or_bootstrap(@family, start_date: @budget.start_date)
    @budget.reload.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 500)
    assert_equal :fully_allocated, @budget.reload.allocation_state

    get budget_path(@budget)

    assert_response :ok
    assert_select "button", text: I18n.t("budgets.show.tabs.budgeted")
  end

  test "a budget that is not set up shows no over-allocation warning" do
    @budget.update!(budgeted_spending: nil)
    Budget.find_or_bootstrap(@family, start_date: @budget.start_date)
    @budget.reload.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 500)

    get budget_path(@budget)

    assert_response :ok
    assert_no_match(/over-allocated your budget/, response.body)
  end
end
