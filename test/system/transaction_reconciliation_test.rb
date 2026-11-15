require "application_system_test_case"

# w3-toolstrx reconciliation-status: mark transactions as cleared in bulk, then filter by status
class TransactionReconciliationTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    @account = accounts(:depository)
    @first = create_entry("First statement line", 12)
    @second = create_entry("Second statement line", 14)
    @untouched = create_entry("Not on the statement", 16)
  end

  test "bulk mark as cleared, then filter by status" do
    visit transactions_url

    find("#" + dom_id(@first, "selection")).check
    find("#" + dom_id(@second, "selection")).check

    within "#entry-selection-bar" do
      find("[data-testid='reconcile-bulk-menu']").click
      click_button I18n.t("transactions.reconcile.bulk.mark_as", status: I18n.t("transactions.reconcile.statuses.cleared"))
    end

    assert_text I18n.t("transactions.bulk_updates.create.success", count: 2)
    assert @first.reload.cleared?
    assert @second.reload.cleared?
    assert @untouched.reload.unreconciled?

    find("#transaction-filters-button").click
    within "#transaction-filters-menu" do
      click_button I18n.t("transactions.search.filters.reconcile_status")
      check I18n.t("transactions.reconcile.statuses.cleared")
      click_button I18n.t("transactions.searches.menu.apply")
    end

    within "ul#transaction-search-filters" do
      assert_text I18n.t("transactions.reconcile.statuses.cleared")
    end
    assert_selector "#" + dom_id(@first)
    assert_selector "#" + dom_id(@second)
    assert_no_selector "#" + dom_id(@untouched)
  end

  test "the row badge moves one step per click" do
    visit transactions_url

    find("#" + dom_id(@untouched, :reconcile_badge)).click

    assert_text I18n.t("transactions.reconcile.success", status: I18n.t("transactions.reconcile.statuses.cleared"))
    assert_selector "##{dom_id(@untouched, :reconcile_badge)}[title='#{I18n.t("transactions.reconcile.badge.cleared_tooltip")}']"
    assert @untouched.reload.cleared?
  end

  private
    def create_entry(name, amount)
      @account.entries.create!(name: name, date: Date.current, amount: amount, currency: "USD", entryable: Transaction.new)
    end
end
