require "test_helper"

class AutoMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @credit_card = accounts(:credit_card)
  end

  test "index lists the family's pending matches" do
    transfer = create_pending_transfer(name: "Card payment")

    get auto_matches_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(transfer)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(transfer)}", text: /Card payment/
  end

  test "index leaves out confirmed transfers and other families' matches" do
    confirmed = create_pending_transfer(name: "Already confirmed")
    confirmed.confirm!
    other = create_other_family_pending_transfer

    get auto_matches_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(confirmed)}", count: 0
    assert_select "##{ActionView::RecordIdentifier.dom_id(other)}", count: 0
  end

  test "index shows the empty state with nothing to review" do
    Transfer.pending.find_each(&:destroy!)

    get auto_matches_url

    assert_response :success
    assert_select "p", text: I18n.t("auto_matches.index.empty_title")
  end

  test "index says when auto-matching is off" do
    @family.update!(auto_match_transfers_disabled: true)

    get auto_matches_url

    assert_response :success
    assert_includes response.body, ERB::Util.html_escape(I18n.t("auto_matches.index.disabled_notice"))
  end

  test "confirm sets the legs' kinds through the transfer" do
    transfer = create_pending_transfer

    patch confirm_auto_match_url(transfer)

    assert_redirected_to auto_matches_url
    assert transfer.reload.confirmed?
    assert_equal "cc_payment", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
  end

  test "reject removes the match, records the rejection and leaves the legs standard" do
    transfer = create_pending_transfer

    assert_difference -> { Transfer.count } => -1, -> { RejectedTransfer.count } => 1 do
      patch reject_auto_match_url(transfer)
    end

    assert_redirected_to auto_matches_url
    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "confirming a match that is no longer pending changes nothing" do
    transfer = create_pending_transfer
    transfer.confirm!

    patch confirm_auto_match_url(transfer)

    assert_redirected_to auto_matches_url
    assert_equal I18n.t("auto_matches.already_resolved"), flash[:notice]
    assert transfer.reload.confirmed?
  end

  test "rejecting a confirmed transfer from the review page does nothing" do
    transfer = create_pending_transfer
    transfer.confirm!

    assert_no_difference -> { Transfer.count } do
      patch reject_auto_match_url(transfer)
    end
  end

  test "another family's match cannot be confirmed" do
    other = create_other_family_pending_transfer

    patch confirm_auto_match_url(other)

    assert other.reload.pending?
  end

  test "bulk confirm confirms every selected pending match" do
    first = create_pending_transfer(amount: 300)
    second = create_pending_transfer(amount: 400)

    patch bulk_update_auto_matches_url, params: { status: "confirmed", transfer_ids: [ first.id, second.id ] }

    assert_redirected_to auto_matches_url
    assert_equal I18n.t("auto_matches.bulk_update.confirmed", count: 2), flash[:notice]
    assert first.reload.confirmed?
    assert second.reload.confirmed?
    assert_equal "cc_payment", second.outflow_transaction.reload.kind
  end

  test "bulk reject rejects every selected pending match" do
    first = create_pending_transfer(amount: 300)
    second = create_pending_transfer(amount: 400)

    assert_difference -> { Transfer.count } => -2, -> { RejectedTransfer.count } => 2 do
      patch bulk_update_auto_matches_url, params: { status: "rejected", transfer_ids: [ first.id, second.id ] }
    end

    assert_equal I18n.t("auto_matches.bulk_update.rejected", count: 2), flash[:notice]
  end

  test "bulk update skips confirmed transfers and other families' matches" do
    pending = create_pending_transfer(amount: 300)
    confirmed = create_pending_transfer(amount: 400)
    confirmed.confirm!
    other = create_other_family_pending_transfer

    assert_difference -> { Transfer.count } => -1 do
      patch bulk_update_auto_matches_url, params: { status: "rejected", transfer_ids: [ pending.id, confirmed.id, other.id ] }
    end

    assert_equal I18n.t("auto_matches.bulk_update.rejected", count: 1), flash[:notice]
    assert Transfer.exists?(confirmed.id)
    assert other.reload.pending?
  end

  test "bulk update without a selection or with an unknown status shows an alert" do
    transfer = create_pending_transfer

    patch bulk_update_auto_matches_url, params: { status: "confirmed" }
    assert_equal I18n.t("auto_matches.bulk_update.invalid_selection"), flash[:alert]

    patch bulk_update_auto_matches_url, params: { status: "deleted", transfer_ids: [ transfer.id ] }
    assert_equal I18n.t("auto_matches.bulk_update.invalid_selection"), flash[:alert]
    assert transfer.reload.pending?
  end

  test "the preferences switch turns auto-matching off and on" do
    patch user_url(users(:family_admin)), params: {
      user: { redirect_to: "preferences", family_attributes: { id: @family.id, auto_match_transfers_enabled: "0" } }
    }

    assert_redirected_to settings_preferences_url
    assert @family.reload.auto_match_transfers_disabled?

    patch user_url(users(:family_admin)), params: {
      user: { redirect_to: "preferences", family_attributes: { id: @family.id, auto_match_transfers_enabled: "1" } }
    }

    assert_not @family.reload.auto_match_transfers_disabled?
  end

  test "a member who is not an admin cannot turn auto-matching off" do
    sign_in users(:family_member)

    patch user_url(users(:family_member)), params: {
      user: { redirect_to: "preferences", family_attributes: { id: @family.id, auto_match_transfers_enabled: "0" } }
    }

    assert_not @family.reload.auto_match_transfers_disabled?
  end

  test "the preferences page shows the switch and the review link" do
    get settings_preferences_url

    assert_response :success
    assert_select "#auto_match_transfers_enabled"
    assert_select "a[href=?]", auto_matches_path
  end

  private
    def create_pending_transfer(amount: 250, name: "Transfer leg")
      outflow = create_transaction(date: Date.current, account: @depository, amount: amount, name: name)
      inflow = create_transaction(date: Date.current, account: @credit_card, amount: -amount)
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)
    end

    def create_other_family_pending_transfer
      family = families(:empty)
      from = family.accounts.create!(name: "Other A", balance: 0, currency: "USD", accountable: Depository.new)
      to = family.accounts.create!(name: "Other B", balance: 0, currency: "USD", accountable: Depository.new)
      outflow = create_transaction(date: Date.current, account: from, amount: 90)
      inflow = create_transaction(date: Date.current, account: to, amount: -90)
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)
    end
end
