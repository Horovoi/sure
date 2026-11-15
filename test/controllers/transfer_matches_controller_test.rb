require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "manual match sets the outflow kind from the destination account" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    inflow_entry = create_transaction(amount: -100, account: accounts(:loan))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: { method: "existing", matched_entry_id: inflow_entry.id }
    }

    assert_equal "loan_payment", outflow_entry.transaction.reload.kind
    assert_equal "funds_movement", inflow_entry.transaction.reload.kind
    assert outflow_entry.transaction.transfer.confirmed?
  end

  test "manually matching an auto-matched pair confirms it" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    inflow_entry = create_transaction(amount: -100, account: accounts(:credit_card))
    transfer = Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)

    assert_no_difference "Transfer.count" do
      post transaction_transfer_match_path(outflow_entry), params: {
        transfer_match: { method: "existing", matched_entry_id: inflow_entry.id }
      }
    end

    assert transfer.reload.confirmed?
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  # w2-transfers transfer-hints
  test "not a transfer removes the hint with a turbo stream and rejects the pair" do
    outflow = create_transaction(amount: 120, account: accounts(:depository))
    inflow = create_transaction(amount: -120, account: accounts(:credit_card))

    assert_difference -> { RejectedTransfer.count }, 1 do
      delete transaction_transfer_match_path(outflow), as: :turbo_stream
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, %(action="remove")
    assert_includes response.body, ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "the matcher shows its copy from the locale" do
    entry = create_transaction(amount: 120, account: accounts(:depository))

    get new_transaction_transfer_match_path(entry)

    assert_response :success
    assert_select "h2", text: /To account/
    assert_includes response.body, "Match the corresponding transaction in another account"
  end
end
