require "application_system_test_case"

# The categorize wizard: open it from the transactions page, give one group a
# category (and a rule), and categorize a single row.
class TransactionCategorizeTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    # Only the transactions this test creates are uncategorized
    Transaction.where(id: @family.entries.where(entryable_type: "Transaction").select(:entryable_id), category_id: nil)
               .update_all(category_id: categories(:subscriptions).id)

    @group = 2.times.map { |i| create_entry("Corner shop", i.days.ago.to_date) }
    @single = create_entry("Bakery", 3.days.ago.to_date)
  end

  test "categorize one group from the transactions page and create its rule" do
    visit transactions_url
    click_link I18n.t("transactions.index.categorize", count: 3)

    assert_selector "#categorize_group_title h2", text: "Corner shop"
    assert_checked_field I18n.t("transactions.categorizes.show.create_rule_label")

    assert_difference -> { @family.rules.count }, 1 do
      within "[data-controller='category-select']" do
        find("button[data-category-select-target='button']").click
        find("button[data-category-id='#{@category.id}']", match: :first).click
      end

      # The wizard moves on to the next group
      assert_selector "#categorize_group_title h2", text: "Bakery"
    end

    @group.each { |entry| assert_equal @category, entry.reload.transaction.category }
    assert_equal "Corner shop", @family.rules.order(:created_at).last.conditions.find_by!(condition_type: "transaction_name").value
  end

  test "the All box in the list header clears and checks every row" do
    visit transactions_categorize_url(position: 0)
    assert_selector "#categorize_group_title h2", text: "Corner shop"

    rows = -> { all("input[name='categorize[entry_ids][]']") }
    all_box = find("#categorize_select_all")
    assert all_box.checked?

    all_box.click
    assert rows.call.none?(&:checked?)

    rows.call.first.click
    assert page.evaluate_script("document.getElementById('categorize_select_all').indeterminate")

    all_box.click
    assert rows.call.all?(&:checked?)
    assert all_box.checked?
  end

  test "pick a category for a single row" do
    visit transactions_categorize_url(position: 1)

    assert_selector "#categorize_group_title h2", text: "Bakery"
    find("select[data-entry-id='#{@single.id}']").select(@category.name)

    assert_eventually { @single.reload.transaction.category == @category }
    # Bakery was the last group: the wizard ends on the transactions page, with Corner shop still to do
    assert_text I18n.t("transactions.categorizes.show.skipped_rest", count: 2)
  end

  private
    def create_entry(name, date)
      @account.entries.create!(name: name, date: date, amount: 12, currency: "USD", entryable: Transaction.new)
    end

    def assert_eventually(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
    end
end
