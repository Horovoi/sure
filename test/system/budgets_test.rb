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
end
