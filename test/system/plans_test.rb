require "application_system_test_case"

class PlansTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @budget = budgets(:one)
  end

  test "the Plan nav item opens the budget and the goals, and each section leads to its page" do
    within("nav", match: :first) { click_link I18n.t("layouts.application.nav.plan") }

    assert_current_path plan_path
    assert_selector "h1", text: I18n.t("plans.show.title")

    within_testid("plan-budget") do
      assert_text @budget.name
      assert_text I18n.t("budgets.budget_donut.spent")
    end
    within_testid("plan-goals") do
      assert_text goals(:vacation_italy).name
      assert_text goals(:emergency_fund).name
      click_link I18n.t("plans.show.goals.all")
    end

    assert_current_path goals_path
    assert_selector "a[aria-current=page][href='#{plan_path}']", minimum: 1
    within("main") { click_link I18n.t("breadcrumbs.plan") }

    assert_current_path plan_path
    within_testid("plan-budget") { click_link I18n.t("plans.show.budget.open") }

    assert_current_path budget_path(@budget)
    assert_selector "a[aria-current=page][href='#{plan_path}']", minimum: 1
    within("main") { click_link I18n.t("breadcrumbs.plan") }

    assert_current_path plan_path
    within_testid("plan-goals") { click_link goals(:vacation_italy).name }

    assert_current_path goal_path(goals(:vacation_italy))
    assert_selector "h1", text: goals(:vacation_italy).name
  end

  test "the phone nav has one Plan item in place of Budgets and Goals" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit root_path

    nav = find("nav.fixed.bottom-0")
    within(nav) do
      assert_link I18n.t("layouts.application.nav.plan"), href: plan_path
      assert_no_link href: budgets_path
      assert_no_link href: goals_path
      click_link I18n.t("layouts.application.nav.plan")
    end

    assert_current_path plan_path
    assert_selector "h1", text: I18n.t("plans.show.title")
    # Nothing on the page is wider than the phone
    assert_equal 0, page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_equal 0, page.evaluate_script("(m => m.scrollWidth - m.clientWidth)(document.querySelector('main'))")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end
end
