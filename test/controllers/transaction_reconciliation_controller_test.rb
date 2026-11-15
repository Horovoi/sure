require "test_helper"

# w3-toolstrx reconciliation-status: the status badge, the filter and the account header
class TransactionReconciliationControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(account: accounts(:depository), name: "Statement line")
  end

  test "the badge moves the status one step and answers with streams" do
    patch reconcile_transaction_path(@entry.transaction), as: :turbo_stream

    assert_response :success
    assert @entry.reload.cleared?
    assert_match %(target="#{ActionView::RecordIdentifier.dom_id(@entry, :reconcile_badge)}"), response.body
    assert_match %(target="#{ActionView::RecordIdentifier.dom_id(@entry.account, :reconciliation_indicator)}"), response.body
    assert_match I18n.t("transactions.reconcile.success", status: I18n.t("transactions.reconcile.statuses.cleared")), response.body
  end

  test "an html request redirects back" do
    patch reconcile_transaction_path(@entry.transaction)

    assert_redirected_to transactions_url
    assert @entry.reload.cleared?
  end

  test "a synced account's transaction is refused" do
    synced = create_transaction(account: accounts(:connected))

    patch reconcile_transaction_path(synced.transaction)

    assert_equal I18n.t("transactions.reconcile.not_manual_account"), flash[:alert]
    assert synced.reload.unreconciled?
  end

  test "another family's transaction is not found" do
    sign_in users(:empty)

    patch reconcile_transaction_path(@entry.transaction)

    assert_response :not_found
    assert @entry.reload.unreconciled?
  end

  test "rows show the badge for manual accounts only" do
    synced = create_transaction(account: accounts(:connected), name: "Synced line")

    get transactions_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :reconcile_badge)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(synced, :reconcile_badge)}", count: 0
  end

  test "the drawer header shows the pill" do
    get transaction_path(@entry)

    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :reconcile_pill)}"
  end

  test "the list filters by status and shows the chip" do
    cleared = create_transaction(account: accounts(:depository), name: "Cleared line", reconciled_status: "cleared")

    get transactions_path(q: { reconcile_status: [ "cleared" ] })

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(cleared)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry)}", count: 0
    assert_select "input[name='q[reconcile_status][]'][value='cleared'][checked]"
  end

  test "the account header shows how many transactions are left to reconcile" do
    get account_path(accounts(:depository))

    assert_response :success
    assert_select "[data-testid='reconciliation-indicator']"
    open_count = Account::ReconciliationIndicator.for(accounts(:depository)).open_count
    assert_match I18n.t("accounts.show.reconciliation_indicator.needs_attention", count: open_count), response.body
  end
end
