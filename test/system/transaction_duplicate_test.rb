require "application_system_test_case"

# Duplicate-and-edit (decision 45, the substitute for splits): select one
# transaction, press Duplicate, change the copy and save it.
class TransactionDuplicateTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)

    @account = accounts(:depository)
    @source = @account.entries.create!(
      name: "Duplicate source", date: Date.current, amount: 42.50, currency: "USD",
      notes: "Copied note", entryable: Transaction.new(category: categories(:food_and_drink))
    )
    @valuation = @account.entries.create!(
      name: "Current balance", date: 1.day.ago.to_date, amount: 1000, currency: "USD", entryable: Valuation.new
    )
  end

  test "duplicate from the account page opens a filled form and saves a second transaction" do
    visit account_url(@account, tab: "activity")

    find("#" + dom_id(@source, "selection")).check

    within "#entry-selection-bar" do
      find("a[title='#{I18n.t("entries.selection_bar.duplicate")}']").click
    end

    within "#modal" do
      assert_field "entry_name", with: "Duplicate source"
      assert_field "entry[amount]", with: "42.50"
      fill_in "entry[amount]", with: "12.50"
      click_button I18n.t("transactions.form.submit")
    end

    assert_text I18n.t("transactions.create.success")
    copy = @account.entries.where(name: "Duplicate source").where.not(id: @source.id).sole
    assert_equal 12.5.to_d, copy.amount
    assert_equal categories(:food_and_drink), copy.transaction.category
    assert_equal "Copied note", copy.notes
    assert_equal 42.5.to_d, @source.reload.amount
  end

  test "duplicate stays hidden for a valuation and for two selected rows" do
    visit account_url(@account, tab: "activity")
    duplicate = "a[title='#{I18n.t("entries.selection_bar.duplicate")}']"

    find("#" + dom_id(@valuation, "selection")).check
    within("#entry-selection-bar") { assert_no_selector duplicate }

    find("#" + dom_id(@source, "selection")).check
    within("#entry-selection-bar") { assert_no_selector duplicate }
  end

  test "duplicate from the transactions page" do
    visit transactions_url

    find("#" + dom_id(@source, "selection")).check

    within "#entry-selection-bar" do
      find("a[title='#{I18n.t("transactions.selection_bar.duplicate")}']").click
    end

    within "#modal" do
      assert_field "entry_name", with: "Duplicate source"
    end
  end
end
