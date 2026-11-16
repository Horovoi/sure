require "test_helper"

class PlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "shows this period's budget and the active goals with links into their pages" do
    budget = budgets(:one)

    get plan_path

    assert_response :ok
    assert_select "h1", text: I18n.t("plans.show.title")
    assert_select "[data-testid=plan-budget]" do
      assert_select "h2", text: /#{Regexp.escape(budget.name)}/
      assert_select "a[href=?]", budget_path(budget), text: I18n.t("plans.show.budget.open")
    end
    assert_select "[data-testid=plan-goals]" do
      assert_select "a[href=?]", goals_path, text: I18n.t("plans.show.goals.all")
      assert_select "a[href=?]", goal_path(goals(:vacation_italy))
      assert_select "a[href=?]", goal_path(goals(:car_paydown))
    end
  end

  test "lists only the goals still being worked on" do
    goals(:vacation_italy).update_columns(state: "completed")
    goals(:emergency_fund).update_columns(state: "archived")

    get plan_path

    assert_select "[data-testid=plan-goals]" do
      assert_select "a[href=?]", goal_path(goals(:car_paydown))
      assert_select "a[href=?]", goal_path(goals(:vacation_italy)), count: 0
      assert_select "a[href=?]", goal_path(goals(:emergency_fund)), count: 0
    end
  end

  test "keeps the link to the goals page when no goal is active" do
    @family.goals.update_all(state: "archived")

    get plan_path

    assert_response :ok
    assert_select "[data-testid=plan-goals]" do
      assert_select "p", text: I18n.t("plans.show.goals.none_active")
      assert_select "a[href=?]", goals_path
    end
  end

  test "offers to create the first goal when the family has none" do
    @family.goals.destroy_all

    get plan_path

    assert_response :ok
    assert_select "[data-testid=plan-goals]" do
      assert_select "h2", text: I18n.t("goals.empty_state.heading")
      assert_select "a[href=?]", new_goal_path, text: I18n.t("goals.empty_state.new_goal")
    end
  end

  test "offers to set up a budget for a period that has none" do
    budgets(:one).update!(budgeted_spending: nil)

    get plan_path

    assert_response :ok
    assert_select "[data-testid=plan-budget]" do
      assert_select "a[href=?]", edit_budget_path(budgets(:one)), text: I18n.t("budgets.budget_donut.new_budget")
    end
  end

  test "shows the fiscal period that holds today" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 15)
    period_start = @family.budget_period_start_for(Date.current)

    get plan_path

    assert_response :ok
    budget = @family.budgets.find_by!(start_date: period_start)
    assert_equal @family.budget_period_end_for(period_start), budget.end_date
    assert_select "[data-testid=plan-budget]" do
      assert_select "a[href=?]", budget_path(budget)
      assert_select "span", text: I18n.t("budgets.period.fiscal_months")
    end
  end

  test "the nav has one Plan item, lit on the plan, budget and goal pages" do
    [ plan_path, budget_path(budgets(:one)), goals_path, goal_path(goals(:vacation_italy)) ].each do |path|
      get path
      assert_response :ok, "GET #{path}"

      assert_select "a[href=?][aria-current=page]", plan_path, minimum: 1, message: "Plan is not lit on #{path}"
      assert_select "nav a[href=?]", budgets_path, count: 0
      assert_select "nav a[href=?]", goals_path, count: 0
    end
  end

  test "budget and goal pages start their breadcrumbs with Plan" do
    get budget_path(budgets(:one))
    assert_select "a[href=?]", plan_path, text: I18n.t("breadcrumbs.plan")
    assert_match I18n.t("breadcrumbs.budgets"), response.body

    get goal_path(goals(:vacation_italy))
    assert_select "a[href=?]", plan_path, text: I18n.t("breadcrumbs.plan")
    assert_select "a[href=?]", goals_path, text: I18n.t("goals.index.title")
  end
end
