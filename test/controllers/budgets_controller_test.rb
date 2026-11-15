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

  test "copying the previous budget fills an empty month and opens the categories step" do
    source = Budget.find_or_bootstrap(@family, start_date: 2.months.ago)
    source.update!(budgeted_spending: 2000, expected_income: 3000)
    source.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 400)
    target = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)

    get budget_path(target)
    assert_select "[data-testid=copy-previous-prompt]"

    post copy_previous_budget_path(target)

    assert_redirected_to budget_budget_categories_path(target)
    assert_equal I18n.t("budgets.copy_previous.success", source_name: source.name), flash[:notice]
    target.reload
    assert_equal 2000, target.budgeted_spending
    assert_equal 400, target.budget_categories.find_by!(category: categories(:food_and_drink)).budgeted_spending
  end

  test "copying the previous budget into a budget that is set up changes nothing" do
    source = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    source.update!(budgeted_spending: 2000)

    post copy_previous_budget_path(@budget)

    assert_redirected_to budget_path(@budget)
    assert_equal I18n.t("budgets.copy_previous.already_initialized"), flash[:alert]
    assert_equal 5000, @budget.reload.budgeted_spending
  end

  test "copying with no earlier budget set up shows an alert" do
    target = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)

    post copy_previous_budget_path(target)

    assert_redirected_to budget_path(target)
    assert_equal I18n.t("budgets.copy_previous.no_source"), flash[:alert]
    assert_nil target.reload.budgeted_spending
  end
end
