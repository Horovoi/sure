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
    assert_no_match(I18n.t("budgets.over_allocation_warning.message"), response.body)
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

  test "a budget 13 months ahead opens" do
    get budget_path(Budget.date_to_param(Date.current.advance(months: 13), family: @family))

    assert_response :ok
  end

  test "a budget more than two years ahead is not found" do
    get budget_path(Budget.date_to_param(Date.current.advance(years: 2, months: 1), family: @family))

    assert_response :not_found
  end

  test "an empty future month offers to copy the newest earlier budget" do
    newer = Budget.find_or_bootstrap(@family, start_date: Date.current.advance(months: 1))
    newer.update!(budgeted_spending: 6000)

    get budget_path(Budget.date_to_param(Date.current.advance(months: 3), family: @family))

    assert_response :ok
    assert_select "[data-testid=copy-previous-prompt]", text: /#{Regexp.escape(newer.name)}/
  end

  # -- w3-reports goals-free-cash --------------------------------------------

  test "the current budget shows the cash panel with the earmark line" do
    get budget_path(@budget)

    assert_response :ok
    assert @budget.shows_available_cash?
    assert_select "#budget_available_cash" do
      assert_select "h2", text: I18n.t("budgets.available_cash.heading")
      assert_select "dt", text: I18n.t("budgets.available_cash.earmarked")
      assert_select "[data-testid='budget-free-cash']", text: /#{Regexp.escape(@budget.free_cash_money.format)}/
      assert_select "a[href=?]", goals_path
    end
  end

  test "a past budget shows no cash panel" do
    past = Budget.find_or_bootstrap(@family, start_date: @family.budget_period_start_for(Date.current) - 1.month)

    get budget_path(past)

    assert_response :ok
    assert_select "#budget_available_cash", count: 0
  end
end
