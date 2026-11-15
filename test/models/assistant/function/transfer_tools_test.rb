require "test_helper"

class Assistant::Function::TransferToolsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @candidates = Assistant::Function::GetTransferMatchCandidates.new(@user)
    @match = Assistant::Function::MatchTransfer.new(@user)
    @review = Assistant::Function::ReviewTransfer.new(@user)
    @unmatch = Assistant::Function::UnmatchTransfer.new(@user)

    # A card payment: money leaves the checking account and arrives on the credit card
    @outflow = create_transaction(account: accounts(:depository), amount: 123.45, name: "Card payment").transaction
    @inflow = create_transaction(account: accounts(:credit_card), amount: -123.45, name: "Payment received").transaction
  end

  # --- Registry and scope tags --------------------------------------------------------------------------------

  test "the chat and the full MCP scope get every transfer tool" do
    names = Assistant.config_for(chats(:one))[:functions].map(&:name)

    %w[get_transfer_match_candidates match_transfer review_transfer unmatch_transfer].each do |name|
      assert_includes names, name
      assert_includes Assistant.function_classes_for(:full).map(&:name), name
    end
  end

  test "scope tags: candidates read, match and review write, unmatch destructive; match and unmatch not idempotent" do
    assert_equal :read, @candidates.scope_tag
    assert_equal :write, @match.scope_tag
    assert_equal :write, @review.scope_tag
    assert_equal :destructive, @unmatch.scope_tag
    assert_not @match.idempotent?
    assert_not @unmatch.idempotent?
    assert @unmatch.mcp_annotations[:destructive_hint]
  end

  # --- get_transfer_match_candidates --------------------------------------------------------------------------

  test "lists the counterpart with the kind the outflow would get" do
    result = @candidates.call("transaction_id" => @outflow.id)

    candidate = result[:candidates].find { |c| c[:transaction_id] == @inflow.id }
    assert candidate, result.inspect
    assert_equal "cc_payment", candidate[:outflow_kind]
    assert_equal 0, candidate[:days_apart]
    assert_equal false, candidate[:previously_rejected]
  end

  test "flags a pairing rejected before" do
    RejectedTransfer.create!(inflow_transaction_id: @inflow.id, outflow_transaction_id: @outflow.id)

    candidate = @candidates.call("transaction_id" => @inflow.id)[:candidates].find { |c| c[:transaction_id] == @outflow.id }

    assert candidate[:previously_rejected]
  end

  test "shows the current transfer instead of candidates" do
    transfer = Transfer.create!(inflow_transaction: @inflow, outflow_transaction: @outflow)

    result = @candidates.call("transaction_id" => @outflow.id)

    assert_equal transfer.id, result[:transfer][:transfer_id]
    assert_equal "pending", result[:transfer][:status]
    assert_empty result[:candidates]
  end

  test "refuses unknown and foreign transactions" do
    assert_equal "not_found", @candidates.call("transaction_id" => "nope")[:error]

    foreign = families(:empty).accounts.create!(name: "Elsewhere", currency: "USD", balance: 0, accountable: Depository.new)
    other = create_transaction(account: foreign, amount: 10).transaction
    assert_equal "not_found", @candidates.call("transaction_id" => other.id)[:error]
  end

  # --- match_transfer -----------------------------------------------------------------------------------------

  test "match gives the legs the kinds the UI flow gives, and the income statement leaves the pair out" do
    ids = [ @outflow.id, @inflow.id ]
    assert_equal 2, pair_totals(ids).transactions_count

    result = nil
    assert_difference "Transfer.count", 1 do
      result = @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
    end

    assert_nil result[:error], result.inspect
    transfer = Transfer.find(result[:transfer_id])
    assert transfer.confirmed?
    assert_equal ids, result[:ids]
    assert_equal "cc_payment", @outflow.reload.kind
    assert_equal "funds_movement", @inflow.reload.kind
    assert_equal 0, pair_totals(ids).transactions_count
  end

  test "match works from either leg and audits both transaction ids" do
    actor = Assistant::ToolInvocation::Actor.new(user: @user, source: "mcp", client_name: "claude-code")

    Assistant::ToolInvocation.call(@match, { "transaction_id" => @inflow.id, "counterpart_transaction_id" => @outflow.id }, actor: actor)

    audit = AiToolAudit.newest_first.first
    assert_equal "ok", audit.status
    assert_equal "Transaction", audit.result_record_type
    assert_equal [ @outflow.id, @inflow.id ], audit.result_record_ids
    assert_equal @inflow, @outflow.reload.transfer.inflow_transaction
  end

  test "dry_run changes nothing" do
    result = nil
    assert_no_difference "Transfer.count" do
      result = @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id, "dry_run" => true)
    end

    assert result[:dry_run]
    assert_equal "cc_payment", result[:outflow_kind]
    assert_equal "standard", @outflow.reload.kind
  end

  test "matching a pending auto-match confirms it" do
    transfer = Transfer.create!(inflow_transaction: @inflow, outflow_transaction: @outflow)

    assert_no_difference "Transfer.count" do
      result = @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
      assert result[:confirmed_pending_match], result.inspect
    end

    assert transfer.reload.confirmed?
    assert_equal "cc_payment", @outflow.reload.kind
  end

  test "matching the same confirmed pair again changes nothing" do
    @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)

    assert_no_difference "Transfer.count" do
      assert @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)[:already_matched]
    end
  end

  test "refuses a pair that is not a candidate and a leg in another transfer" do
    far = create_transaction(account: accounts(:credit_card), amount: -50, name: "Other").transaction
    assert_equal "not_a_candidate", @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => far.id)[:error]

    @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
    second = create_transaction(account: accounts(:other_asset), amount: -123.45).transaction
    assert_equal "already_linked", @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => second.id)[:error]
  end

  # --- review_transfer ----------------------------------------------------------------------------------------

  test "confirm sets the kinds; reject removes the match and records the pairing" do
    pending = Transfer.create!(inflow_transaction: @inflow, outflow_transaction: @outflow)
    assert_equal "standard", @outflow.reload.kind, "a pending match leaves the kinds alone"

    result = @review.call("transfer_id" => pending.id, "action" => "confirm")
    assert_equal "confirmed", result[:action]
    assert_equal [ @outflow.id, @inflow.id ], result[:ids]
    assert_equal "cc_payment", @outflow.reload.kind

    assert_equal "not_pending", @review.call("transfer_id" => pending.id, "action" => "reject")[:error]
  end

  test "reject unlinks a pending match and keeps auto-match away from the pair" do
    pending = Transfer.create!(inflow_transaction: @inflow, outflow_transaction: @outflow)

    result = @review.call("transfer_id" => pending.id, "action" => "reject")

    assert_equal "rejected", result[:action]
    assert_not Transfer.exists?(pending.id)
    assert RejectedTransfer.exists?(inflow_transaction_id: @inflow.id, outflow_transaction_id: @outflow.id)
    assert_equal({ @outflow.id => "standard", @inflow.id => "standard" }, result[:kinds_after])
  end

  test "review refuses unknown actions and ids" do
    assert_equal "invalid_action", @review.call("transfer_id" => SecureRandom.uuid, "action" => "maybe")[:error]
    assert_equal "not_found", @review.call("transfer_id" => SecureRandom.uuid, "action" => "confirm")[:error]
  end

  # --- unmatch_transfer ---------------------------------------------------------------------------------------

  test "unmatch gives the kinds back as the UI Remove does and keeps both transactions" do
    @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
    transfer = @outflow.reload.transfer
    before = @unmatch.audit_before("transaction_id" => @inflow.id)

    result = nil
    assert_difference "Transfer.count", -1 do
      assert_no_difference "Transaction.count" do
        result = @unmatch.call("transaction_id" => @inflow.id)
      end
    end

    assert_nil result[:error], result.inspect
    assert_equal transfer.id, result[:transfer_id]
    assert_equal [ @outflow.id, @inflow.id ], result[:ids]
    assert_equal "standard", @outflow.reload.kind
    assert_equal "standard", @inflow.reload.kind
    assert RejectedTransfer.exists?(inflow_transaction_id: @inflow.id, outflow_transaction_id: @outflow.id)
    assert_equal transfer.id, before[:transfer_id]
    assert_equal "confirmed", before[:status]
    assert_equal 2, pair_totals([ @outflow.id, @inflow.id ]).transactions_count
  end

  test "unmatch with reject false does not record a rejection, and dry_run changes nothing" do
    @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
    transfer_id = @outflow.reload.transfer.id

    assert_no_difference "Transfer.count" do
      assert @unmatch.call("transfer_id" => transfer_id, "dry_run" => true)[:dry_run]
    end

    @unmatch.call("transfer_id" => transfer_id, "reject" => false)

    assert_not Transfer.exists?(transfer_id)
    assert_not RejectedTransfer.exists?(inflow_transaction_id: @inflow.id, outflow_transaction_id: @outflow.id)
  end

  test "unmatch keeps both entries and their amounts, so balances stay" do
    @match.call("transaction_id" => @outflow.id, "counterpart_transaction_id" => @inflow.id)
    entries_before = Entry.where(entryable_id: [ @outflow.id, @inflow.id ]).pluck(:id, :amount).sort

    @unmatch.call("transaction_id" => @outflow.id)

    assert_equal entries_before, Entry.where(entryable_id: [ @outflow.id, @inflow.id ]).pluck(:id, :amount).sort
  end

  test "unmatch needs exactly one id and a transfer" do
    assert_equal "invalid_arguments", @unmatch.call({})[:error]
    assert_equal "invalid_arguments", @unmatch.call("transaction_id" => @outflow.id, "transfer_id" => SecureRandom.uuid)[:error]
    assert_equal "not_found", @unmatch.call("transaction_id" => @outflow.id)[:error]
  end

  private
    def pair_totals(ids)
      IncomeStatement.new(@family).totals(
        transactions_scope: @family.transactions.visible.excluding_pending.where(id: ids),
        date_range: Period.last_30_days.date_range
      )
    end
end
