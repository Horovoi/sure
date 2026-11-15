# Confirms or rejects a pending auto-matched transfer, as Confirm and Reject on an auto-matched transaction and the
# auto-match review page do: Transfer#confirm! (which sets the legs' kinds) or Transfer#reject! (which records the
# pairing so auto-match never suggests it again). Fork-native version of upstream 13c03a360.
class Assistant::Function::ReviewTransfer < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  ACTIONS = %w[confirm reject].freeze

  scope_tag :write

  class << self
    def name
      "review_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Confirms or rejects a transfer that Sure auto-matched and nobody has
        reviewed yet (status "pending" in get_transfer_match_candidates).

        confirm keeps the match: both transactions stop counting as income and
        spending. reject unlinks them, keeps both as ordinary transactions and
        stops auto-match from suggesting that pairing again.

        Only pending transfers can be reviewed; unmatch_transfer unlinks a
        confirmed one. Returns the transfer id and both transaction ids.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transfer_id action],
      properties: {
        transfer_id: {
          type: "string",
          description: "Transfer id from get_transfer_match_candidates."
        },
        action: {
          type: "string",
          enum: ACTIONS,
          description: "confirm or reject."
        }
      }
    )
  end

  def record_type
    "Transaction"
  end

  def audit_before(params)
    transfer = find_transfer(params["transfer_id"])
    transfer && serialize_transfer(transfer)
  end

  def call(params = {})
    return tool_error("invalid_action", "action must be one of: #{ACTIONS.join(", ")}.") unless ACTIONS.include?(params["action"])

    transfer = find_transfer(params["transfer_id"])
    return tool_error("not_found", "Use a transfer id from get_transfer_match_candidates.") unless transfer
    return not_pending(transfer) unless transfer.pending?

    before = serialize_transfer(transfer)
    confirm = params["action"] == "confirm"

    # Locked and checked again, so of two reviews only the first acts: a reject must not remove a transfer another
    # call has just confirmed
    reviewed = Transfer.transaction do
      transfer.lock!
      next false unless transfer.pending?

      confirm ? transfer.confirm! : transfer.reject!
      true
    end
    return tool_error("not_pending", "The auto-match was reviewed meanwhile; it is no longer pending.") unless reviewed

    if confirm
      transfer.reload
      { transfer_id: transfer.id, ids: leg_ids(transfer), action: "confirmed", transfer: serialize_transfer(transfer) }
    else
      ids = [ before[:outflow][:transaction_id], before[:inflow][:transaction_id] ]
      kinds = Transaction.where(id: ids).pluck(:id, :kind).to_h
      { transfer_id: before[:transfer_id], ids: ids, action: "rejected", transfer: before, kinds_after: kinds }
    end
  end

  private
    def not_pending(transfer)
      tool_error("not_pending", "Only pending auto-matches can be reviewed; this transfer is #{transfer.status}. unmatch_transfer unlinks a confirmed one.")
    end
end
