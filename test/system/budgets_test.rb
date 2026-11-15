require "application_system_test_case"

class BudgetsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "an empty month offers to copy the previous budget, and copying opens the categories step" do
    source = Budget.find_or_bootstrap(@family, start_date: 2.months.ago)
    source.update!(budgeted_spending: 2000, expected_income: 3000)
    source.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 300)
    target = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)

    visit budget_path(target)

    within_testid("copy-previous-prompt") do
      assert_text I18n.t("budgets.copy_previous_prompt.title")
      click_button I18n.t("budgets.copy_previous_prompt.copy_button", source_name: source.name)
    end

    assert_text I18n.t("budgets.copy_previous.success", source_name: source.name)
    assert_current_path budget_budget_categories_path(target)

    row = target.reload.budget_categories.find_by!(category: categories(:food_and_drink))
    assert_equal 300, find_field(id: ActionView::RecordIdentifier.dom_id(row, :budgeted_spending)).value.to_d
  end

  test "the filter tabs show over budget and on track rows in the light theme" do
    assert_budget_filter_tabs(theme: "light")
  end

  test "the filter tabs show over budget and on track rows in the dark theme" do
    assert_budget_filter_tabs(theme: "dark")
  end

  test "the on track tab shows an empty state when every row is over budget" do
    budget = filter_test_budget
    budget.update!(budgeted_spending: budget.allocated_spending)
    filter_test_entry(categories(:subscriptions), 900)

    visit budget_path(budget, filter: "on_track")

    within_testid("budget-section-on-track") do
      assert_text I18n.t("budgets.show.on_track_categories.empty")
    end
    assert_no_selector "[data-testid='budget-section-over-budget']"
  end

  test "a budget with nothing over budget has no filter tabs" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 100_000, expected_income: 100_000)

    visit budget_path(budget)

    assert_selector "[data-testid='budget-section-on-track']"
    assert_no_selector "[data-testid='budget-filter-over_budget']"
  end

  test "the budget page shows what is reserved for a due subscription" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 10_000, expected_income: 10_000)
    budget.budget_categories.find_by!(category: categories(:subscriptions)).update!(budgeted_spending: 500)
    # Due on the last day of the period, so it is still ahead whatever today is
    @family.recurring_transactions.create!(
      name: "Streaming service", amount: 25, currency: @family.currency, manual: true, status: "active",
      expected_day_of_month: budget.end_date.day, last_occurrence_date: budget.end_date.prev_month,
      next_expected_date: budget.end_date, category: categories(:subscriptions)
    )
    reserved_text = Money.new(25, @family.currency).format

    visit budget_path(budget, tab: "actuals")

    within_testid("budget-reserved-summary") do
      assert_text I18n.t("budgets.subscription_reservations.reserved")
      assert_text reserved_text
    end

    within_testid("budget-category-reserved") do
      assert_text I18n.t("budgets.subscription_reservations.reserved")
      assert_text reserved_text
    end
    assert_selector "[data-testid='budget-category-reserved-bar']"

    find("[data-testid='budget-category-reserved']").click

    within_testid("budget-category-reserved-detail") do
      assert_text I18n.t("budgets.subscription_reservations.reserved")
      assert_text reserved_text
    end
  end

  # Food & Drink is over budget, Subscriptions is on track.
  def filter_test_budget
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 10_000, expected_income: 10_000)
    budget.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 50)
    budget.budget_categories.find_by!(category: categories(:subscriptions)).update!(budgeted_spending: 500)
    filter_test_entry(categories(:food_and_drink), 400)
    filter_test_entry(categories(:subscriptions), 10)
    budget
  end

  def filter_test_entry(category, amount)
    Entry.create!(
      account: accounts(:depository), entryable: Transaction.new(category: category),
      date: Date.current, name: "#{category.name} spending", amount: amount, currency: "USD"
    )
  end

  def assert_budget_filter_tabs(theme:)
    @user.update!(theme: theme)
    budget = filter_test_budget

    visit budget_path(budget)
    assert_selector "html[data-theme='#{theme}']", visible: :all

    # All: both sections.
    within_testid("budget-section-over-budget") { assert_text categories(:food_and_drink).name }
    within_testid("budget-section-on-track") { assert_text categories(:subscriptions).name }

    find("[data-testid='budget-filter-over_budget']").click
    assert_selector "[data-testid='budget-filter-over_budget'][aria-pressed='true'].bg-container.text-primary"
    within_testid("budget-section-over-budget") do
      assert_text categories(:food_and_drink).name
      assert_no_text categories(:subscriptions).name
    end
    assert_no_selector "[data-testid='budget-section-on-track']"
    assert_current_path budget_path(budget, filter: "over_budget")

    find("[data-testid='budget-filter-on_track']").click
    within_testid("budget-section-on-track") do
      assert_text categories(:subscriptions).name
      assert_no_text categories(:food_and_drink).name
    end
    assert_no_selector "[data-testid='budget-section-over-budget']"
    assert_current_path budget_path(budget, filter: "on_track")

    find("[data-testid='budget-filter-all']").click
    assert_selector "[data-testid='budget-section-over-budget']"
    assert_selector "[data-testid='budget-section-on-track']"
    assert_current_path budget_path(budget)
  end

  # w3-envelope envelope-budgeting
  test "editing a subcategory amount changes its parent's row in the categories step" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    budget.update!(budgeted_spending: 10_000, expected_income: 10_000)
    parent = budget.budget_categories.find_by!(category: categories(:food_and_drink))
    child = budget.budget_categories.find_by!(category: categories(:subcategory))
    parent.update!(budgeted_spending: 400)

    visit budget_budget_categories_path(budget)

    parent_field_id = ActionView::RecordIdentifier.dom_id(parent, :budgeted_spending)
    child_field_id = ActionView::RecordIdentifier.dom_id(child, :budgeted_spending)
    assert_equal 400, find_field(id: parent_field_id).value.to_d

    # Number fields submit on change, which the browser fires when the field loses focus
    child_field = find_field(id: child_field_id)
    child_field.set("150")
    child_field.send_keys(:tab)

    assert_selector "##{parent_field_id}" do |field|
      field.value.to_d == 550
    end
    assert_equal 550, parent.reload.budgeted_spending
  end
end
