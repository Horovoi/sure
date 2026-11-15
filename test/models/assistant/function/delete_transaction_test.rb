require "test_helper"

class Assistant::Function::DeleteTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @fn = Assistant::Function::DeleteTransaction.new(@user)
  end

  test "is a destructive tool" do
    assert_equal :destructive, @fn.scope_tag
    assert_equal true, @fn.mcp_annotations[:destructive_hint]
    assert_equal "Transaction", @fn.record_type
  end

  test "deletes the entry and its transaction, syncs, and repeats what was deleted" do
    entry_id = @transaction.entry.id
    Entry.any_instance.expects(:sync_account_later).once

    result = @fn.call("id" => @transaction.id)

    assert result[:deleted]
    assert_equal @transaction.id, result[:id]
    assert_equal "Starbucks", result.dig(:transaction, :name)
    assert_not Entry.exists?(entry_id)
    assert_not Transaction.exists?(@transaction.id)
  end

  test "audit_before keeps everything needed to create it again" do
    before = @fn.audit_before("id" => @transaction.id)

    assert_equal @transaction.entry.account_id, before[:account_id]
    assert_equal @transaction.entry.date.iso8601, before[:date]
    assert_equal @transaction.entry.amount.to_s("F"), before[:amount]
    assert_equal @transaction.category_id, before[:category_id]
  end

  test "an account_id guard that does not match is not_found" do
    assert_no_difference -> { Entry.count } do
      assert_equal "not_found", @fn.call("id" => @transaction.id, "account_id" => accounts(:credit_card).id)[:error]
    end
  end

  test "deleting a transfer leg leaves the other leg as a standard transaction" do
    inflow = transactions(:transfer_in)

    result = @fn.call("id" => transactions(:transfer_out).id)

    assert result[:deleted]
    assert_equal "standard", inflow.reload.kind
    assert_nil inflow.transfer
  end

  test "refuses unknown and malformed ids" do
    assert_equal "not_found", @fn.call("id" => SecureRandom.uuid)[:error]
    assert_equal "not_found", @fn.call("id" => "1; DROP TABLE entries")[:error]
  end
end
