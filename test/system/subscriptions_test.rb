require "application_system_test_case"

class SubscriptionsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "the Suggestions page turns automatic detection off and on" do
    visit suggestions_subscriptions_path

    within_testid("recurring-detection-settings") do
      assert_text I18n.t("subscriptions.suggestions.detection.label")
      find("label[for='recurring_detection_enabled']").click
    end

    assert_text I18n.t("subscriptions.update_detection_settings.disabled")
    assert @family.reload.recurring_transactions_disabled?

    within_testid("recurring-detection-settings") do
      assert_no_selector "#recurring_detection_enabled:checked", visible: :all
      find("label[for='recurring_detection_enabled']").click
    end

    assert_text I18n.t("subscriptions.update_detection_settings.enabled")
    assert_not @family.reload.recurring_transactions_disabled?
  end

  test "a manual recurring row is paused and resumed on the Other recurring tab" do
    rent = @family.recurring_transactions.create!(
      name: "Rent", amount: 800, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current.beginning_of_month, next_expected_date: Date.current.next_month.beginning_of_month,
      status: "active", manual: true, occurrence_count: 3
    )

    visit subscriptions_path
    within_testid("subscriptions-kind-filter") do
      click_link I18n.t("subscriptions.index.filter.other_recurring")
    end

    within "##{ActionView::RecordIdentifier.dom_id(rent)}" do
      assert_text "Rent"
      assert_text I18n.t("subscriptions.status.active")
      within_testid("other-recurring-menu") { find("button[data-DS--menu-target='button']").click }
      click_button I18n.t("subscriptions.other_recurring.pause")
    end

    within "##{ActionView::RecordIdentifier.dom_id(rent)}" do
      assert_text I18n.t("subscriptions.status.inactive")
    end
    assert rent.reload.inactive?

    within "##{ActionView::RecordIdentifier.dom_id(rent)}" do
      within_testid("other-recurring-menu") { find("button[data-DS--menu-target='button']").click }
      click_button I18n.t("subscriptions.other_recurring.resume")
    end

    within "##{ActionView::RecordIdentifier.dom_id(rent)}" do
      assert_text I18n.t("subscriptions.status.active")
    end
    assert rent.reload.active?
  end
end
