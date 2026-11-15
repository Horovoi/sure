require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "should get new" do
    get new_transfer_url
    assert_response :success
  end

  test "can create transfers" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          name: "Test Transfer"
        }
      }
      assert_enqueued_with job: SyncJob
    end
  end

  test "soft deletes transfer" do
    assert_difference -> { Transfer.count }, -1 do
      delete transfer_url(transfers(:one))
    end
  end

  test "removing a transfer records a rejection so auto-match does not pair it again" do
    transfer = transfers(:one)

    assert_difference -> { RejectedTransfer.count } => 1, -> { Transfer.count } => -1 do
      delete transfer_url(transfer)
    end

    assert_equal "standard", transactions(:transfer_in).reload.kind
    assert_equal "standard", transactions(:transfer_out).reload.kind
  end

  test "removing a transfer twice returns not found" do
    transfer = transfers(:one)
    delete transfer_url(transfer)
    delete transfer_url(transfer)

    assert_response :not_found
  end

  test "confirming an already confirmed transfer is harmless" do
    transfer = transfers(:one)
    transfer.confirm!

    patch transfer_url(transfer), params: { transfer: { status: "confirmed" } }

    assert transfer.reload.confirmed?
  end

  test "can add notes to transfer" do
    transfer = transfers(:one)
    assert_nil transfer.notes

    patch transfer_url(transfer), params: { transfer: { notes: "Test notes" } }

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]
    assert_equal "Test notes", transfer.reload.notes
  end

  test "handles rejection without FrozenError" do
    transfer = transfers(:one)

    assert_difference "Transfer.count", -1 do
      patch transfer_url(transfer), params: {
        transfer: {
          status: "rejected"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]

    # Verify the transfer was actually destroyed
    assert_raises(ActiveRecord::RecordNotFound) do
      transfer.reload
    end
  end

  test "creates a transfer from an ISO date" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: 2.days.ago.to_date.iso8601,
          amount: 100
        }
      }
    end

    assert_equal 2.days.ago.to_date, Transfer.order(:created_at).last.date
    assert_equal "Transfer created", flash[:notice]
  end

  test "a blank transfer date shows the form again" do
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: "",
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "Date can&#39;t be blank", response.body
  end

  test "a bad transfer date shows the form again instead of a server error" do
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: "not-a-date",
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "Date is invalid", response.body
  end
end
