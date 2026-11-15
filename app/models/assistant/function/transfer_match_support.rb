# Shared by the transfer tools (get_transfer_match_candidates, match_transfer, review_transfer, unmatch_transfer).
# Fork-native version of upstream 13c03a360 and 12e21f778: the candidates come from the same query as the "Match
# transfer" dialog (Transaction#transfer_match_candidates over Family::AutoTransferMatchable), and every change goes
# through the Transfer model, as the UI does. Upstream's Transfer::Matcher and split-transaction code are not
# ported.
#
# The tools never write transactions.kind. Transfer is the single kind writer: a transfer created confirmed and the
# confirm event set the legs' kinds, and reject and destroy set them back to standard.
#
# The fork has one family and no account sharing, so any transaction or transfer of the family can be named.
module Assistant::Function::TransferMatchSupport
  private
    def find_transaction(id)
      return nil unless valid_uuid?(id)

      family.transactions.includes(entry: :account).find_by(id: id)
    end

    # A transfer whose two legs are in the family's accounts
    def find_transfer(id)
      return nil unless valid_uuid?(id)

      family_transfers.find_by(id: id)
    end

    def find_transfer_for_transaction(id)
      return nil unless valid_uuid?(id)

      family_transfers.where("inflow_transaction_id = :id OR outflow_transaction_id = :id", id: id).first
    end

    def family_transfers
      ids = family.transactions.select(:id)
      Transfer.where(inflow_transaction_id: ids).where(outflow_transaction_id: ids)
    end

    def serialize_transaction(transaction)
      entry = transaction.entry

      {
        transaction_id: transaction.id,
        entry_id: entry.id,
        account_id: entry.account_id,
        account: entry.account.name,
        name: entry.name,
        date: entry.date.iso8601,
        amount: entry.amount.abs.to_s("F"),
        currency: entry.currency,
        direction: entry.amount.negative? ? "inflow" : "outflow",
        kind: transaction.kind,
        excluded: entry.excluded?
      }
    end

    def serialize_transfer(transfer)
      {
        transfer_id: transfer.id,
        name: transfer.name,
        status: transfer.status,
        outflow: serialize_transaction(transfer.outflow_transaction),
        inflow: serialize_transaction(transfer.inflow_transaction),
        fee_transaction_ids: transfer.fee_transactions.pluck(:id)
      }
    end

    # The kind the outflow leg takes when the pair is confirmed (Transfer.outflow_kind_for), so the model can tell a
    # move between own accounts (funds_movement) from a card or loan payment, which budgets treat differently
    def outflow_kind(outflow, inflow)
      Transfer.outflow_kind_for(source_account: outflow.entry.account, destination_account: inflow.entry.account)
    end

    # [outflow, inflow] of two transactions, by the sign of the first one's amount
    def legs_of(transaction, counterpart)
      transaction.entry.amount.negative? ? [ counterpart, transaction ] : [ transaction, counterpart ]
    end

    # The two legs of a transfer, the ids the audit names
    def leg_ids(transfer)
      [ transfer.outflow_transaction_id, transfer.inflow_transaction_id ]
    end

    def boolean_param(params, key, default:)
      return default if params[key].nil?

      ActiveModel::Type::Boolean.new.cast(params[key])
    end
end
