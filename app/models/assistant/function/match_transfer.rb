# Links two existing transactions into a confirmed transfer, as "Match transfer" with an existing transaction does
# (TransferMatchesController#create). The counterpart must be one of get_transfer_match_candidates; a pair that is
# already a pending auto-match is confirmed instead. Fork-native version of upstream 13c03a360, without creating a
# counterpart in another account and without split transactions.
#
# The legs' kinds are set by Transfer (after_create, or the confirm event), never here.
class Assistant::Function::MatchTransfer < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  scope_tag :write

  class << self
    def name
      "match_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Links two existing transactions as one transfer between the family's
        own accounts, so they stop counting as income and spending and the
        accounts' balances stay as they are. A payment to a loan still counts
        as spending in budgets.

        counterpart_transaction_id must be a candidate from
        get_transfer_match_candidates. If the two are already a pending
        auto-match, the match is confirmed. A transaction in another transfer
        is refused with already_linked; unmatch_transfer or review_transfer
        frees it first. Matching the same confirmed pair again changes nothing.

        Pass dry_run: true to see the result (with the outflow kind) without
        changing anything. Returns the transfer id and both transaction ids.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transaction_id counterpart_transaction_id],
      properties: {
        transaction_id: {
          type: "string",
          description: "Transaction id from get_transactions."
        },
        counterpart_transaction_id: {
          type: "string",
          description: "The opposite transaction, from get_transfer_match_candidates."
        },
        dry_run: {
          type: "boolean",
          description: "Describe the change without making it (default false)."
        }
      }
    )
  end

  def record_type
    "Transaction"
  end

  def call(params = {})
    transaction = find_transaction(params["transaction_id"])
    return tool_error("not_found", "Use a transaction id from get_transactions.") unless transaction

    counterpart = find_transaction(params["counterpart_transaction_id"])
    return tool_error("counterpart_not_found", "Use a counterpart id from get_transfer_match_candidates.") unless counterpart

    dry_run = boolean_param(params, "dry_run", default: false)
    outflow, inflow = legs_of(transaction, counterpart)

    if (problem = existing_link_problem(transaction, counterpart))
      return problem
    end

    pending = pending_pair(outflow, inflow)

    unless pending || candidate?(transaction, counterpart)
      return tool_error(
        "not_a_candidate",
        "The two cannot form a transfer: they need opposite amounts (equal, or within 5% across currencies) in two " \
        "different accounts, at most 30 days apart. get_transfer_match_candidates lists the ones that can."
      )
    end

    if dry_run
      return {
        dry_run: true,
        confirms_pending_match: pending.present?,
        outflow: serialize_transaction(outflow),
        inflow: serialize_transaction(inflow),
        outflow_kind: outflow_kind(outflow, inflow)
      }
    end

    transfer = pending ? confirm_pending(pending) : create_confirmed(outflow, inflow)
    return transfer if transfer.is_a?(Hash)

    transfer.sync_account_later
    transfer.reload

    {
      transfer_id: transfer.id,
      ids: leg_ids(transfer),
      confirmed_pending_match: pending.present?,
      transfer: serialize_transfer(transfer)
    }
  end

  private
    # nil when both legs are free, or when they are already this same confirmed transfer (an answer, not an error)
    def existing_link_problem(transaction, counterpart)
      [ transaction, counterpart ].each do |leg|
        next if leg.fee_transfer_id.blank?

        return tool_error("fee_transaction", "#{leg.id} is the fee of a transfer and cannot be a transfer leg.")
      end

      existing = transaction.transfer || counterpart.transfer
      return nil unless existing
      return nil if existing.pending? && same_pair?(existing, transaction, counterpart)

      if existing.confirmed? && same_pair?(existing, transaction, counterpart)
        return { transfer_id: existing.id, ids: leg_ids(existing), already_matched: true, transfer: serialize_transfer(existing) }
      end

      tool_error(
        "already_linked",
        existing.pending? ? "One of the transactions is in another pending auto-match; reject it with review_transfer first." :
          "One of the transactions is already in another transfer; unmatch_transfer frees it first.",
        transfer: serialize_transfer(existing)
      )
    end

    def same_pair?(transfer, transaction, counterpart)
      leg_ids(transfer).sort == [ transaction.id, counterpart.id ].sort
    end

    def pending_pair(outflow, inflow)
      transfer = outflow.transfer
      transfer if transfer&.pending? && transfer.inflow_transaction_id == inflow.id && transfer.outflow_transaction_id == outflow.id
    end

    def candidate?(transaction, counterpart)
      transaction.transfer_match_candidates.any? do |candidate|
        [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ].include?(counterpart.id)
      end
    end

    # Locked and checked again, so a review landing meanwhile cannot be confirmed twice or confirmed after a reject
    def confirm_pending(pending)
      confirmed = Transfer.transaction do
        pending.lock!
        next false unless pending.pending?

        pending.confirm!
        true
      end

      confirmed ? pending : tool_error("not_pending", "The auto-match was reviewed meanwhile; call get_transfer_match_candidates again.")
    end

    # The family's matching lock serializes this with auto-match and rejects; locking both legs keeps two calls from
    # putting one transaction into two transfers (the unique leg indexes would refuse the second one anyway)
    def create_confirmed(outflow, inflow)
      leg_ids = [ outflow.id, inflow.id ]

      transfer = Transfer.transaction do
        family.lock_transfer_matching!
        Transaction.where(id: leg_ids.sort).order(:id).lock.pluck(:id)
        next nil if Transfer.where(inflow_transaction_id: leg_ids).or(Transfer.where(outflow_transaction_id: leg_ids)).exists?

        Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
      end

      transfer || linked_meanwhile
    rescue ActiveRecord::RecordNotUnique
      linked_meanwhile
    end

    def linked_meanwhile
      tool_error("already_linked", "One of the transactions was linked into a transfer meanwhile; call get_transfer_match_candidates again.")
    end
end
