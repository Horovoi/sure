require "application_system_test_case"

# The transaction rows and the subscriptions table set their columns by their own
# width (container queries), not the window's: between both side panels a row once
# squeezed its name to nothing, and on a phone the subscriptions table scrolled sideways.
class TransactionListLayoutTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @entry = create_transaction(account: accounts(:depository), name: "Corner shop groceries", amount: 42)
  end

  test "a row between both side panels keeps its name and puts the category under it" do
    @user.update!(show_sidebar: true, show_ai_sidebar: true)
    sign_in @user
    visit transactions_path

    within "##{ActionView::RecordIdentifier.dom_id(@entry)}" do
      name = find("a", text: "Corner shop groceries")
      assert_operator name.native.rect.width, :>, 100
      assert_selector "#category_name_mobile_#{@entry.entryable.id}", visible: true
    end
  end

  test "a wide row shows the category pill in its column, under the header" do
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    sign_in @user
    visit transactions_path

    header = find("p", text: I18n.t("transactions.results.col_category"), visible: true)
    within "##{ActionView::RecordIdentifier.dom_id(@entry)}" do
      assert_no_selector "#category_name_mobile_#{@entry.entryable.id}", visible: true
      pill = find("[data-category-badge]", visible: true)
      assert_in_delta header.native.rect.x, pill.native.rect.x, 2
    end
  end

  test "subscriptions are cards on a phone, with nothing to scroll sideways" do
    @family.recurring_transactions.destroy_all
    @family.recurring_transactions.create!(
      name: "A yearly cloud storage plan with a long name", amount: 99, currency: "USD",
      expected_day_of_month: 5, expected_month: 3, billing_cycle: "yearly",
      last_occurrence_date: Date.current.beginning_of_month, next_expected_date: Date.current,
      status: "active", manual: true, occurrence_count: 3, subscription_state: "subscription"
    )
    sign_in @user
    page.driver.browser.manage.window.resize_to(390, 900)
    visit subscriptions_path

    assert_text "A yearly cloud storage plan with a long name"
    assert_no_selector "thead", visible: true
    assert_equal 0, page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end
end
