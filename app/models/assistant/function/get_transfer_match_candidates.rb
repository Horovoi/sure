# The read half of match_transfer: whether a transaction is already in a transfer (a pending auto-match included)
# and, if not, which transactions it could be matched with. Same candidates, in the same order, as the "Match
# transfer" dialog (Transaction#transfer_match_candidates). Fork-native version of upstream 13c03a360.
class Assistant::Function::GetTransferMatchCandidates < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  MAX_CANDIDATES = 25

  class << self
    def name
      "get_transfer_match_candidates"
    end

    def description
      <<~INSTRUCTIONS
        Shows how a transaction can be matched as a transfer between the
        family's own accounts (a move to savings, a currency exchange, a card
        or loan payment).

        Returns the transaction's current transfer, if any. Status "pending" is
        an auto-match Sure suggested that nobody has reviewed yet;
        review_transfer confirms or rejects it.

        Otherwise returns candidate transactions in other accounts: the
        opposite direction, the same amount (or, across currencies, within 5%
        of the converted amount), at most 30 days apart, likeliest first.
        previously_rejected marks a pairing that was rejected before.
        outflow_kind is what the outflow leg becomes when matched:
        funds_movement, cc_payment, loan_payment or investment_contribution.

        match_transfer links the transaction with a candidate.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transaction_id],
      properties: {
        transaction_id: {
          type: "string",
          description: "Transaction id from get_transactions."
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["transaction_id"])
    return tool_error("not_found", "Use a transaction id from get_transactions.") unless transaction

    result = { transaction: serialize_transaction(transaction) }

    if (transfer = transaction.transfer)
      return result.merge(transfer: serialize_transfer(transfer), candidates: [])
    end

    if transaction.fee_transfer_id.present?
      return result.merge(candidates: [], note: "This transaction is the fee of a transfer, so it cannot be a transfer leg itself.")
    end

    candidates = transaction.transfer_match_candidates.first(MAX_CANDIDATES)
    counterpart_ids = candidates.map { |c| counterpart_id(c, transaction) }
    counterparts = Transaction.includes(entry: :account).where(id: counterpart_ids).index_by(&:id)
    rejected = rejected_counterpart_ids(transaction)

    result[:candidates] = candidates.filter_map do |candidate|
      counterpart = counterparts[counterpart_id(candidate, transaction)]
      next unless counterpart

      outflow, inflow = legs_of(transaction, counterpart)
      serialize_transaction(counterpart).merge(
        days_apart: (counterpart.entry.date - transaction.entry.date).to_i.abs,
        previously_rejected: rejected.include?(counterpart.id),
        outflow_kind: outflow_kind(outflow, inflow)
      )
    end

    result
  end

  private
    def counterpart_id(candidate, transaction)
      candidate.inflow_transaction_id == transaction.id ? candidate.outflow_transaction_id : candidate.inflow_transaction_id
    end

    def rejected_counterpart_ids(transaction)
      (RejectedTransfer.where(inflow_transaction_id: transaction.id).pluck(:outflow_transaction_id) +
        RejectedTransfer.where(outflow_transaction_id: transaction.id).pluck(:inflow_transaction_id)).to_set
    end
end
