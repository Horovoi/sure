# Unlinks a transfer, confirmed or pending, so a wrong match can be undone. Both transactions stay; Transfer sets
# the legs' transfer kinds back to standard. Balances do not change. Fork-native version of upstream 12e21f778.
#
# By default it records the pairing as rejected (Transfer#reject!, the Remove button), so auto-match never suggests
# it again, and the transfer's fees stay as plain expenses. reject: false only removes the transfer
# (Transfer#destroy!), which also deletes its fee transactions. The audit keeps the whole transfer from before.
class Assistant::Function::UnmatchTransfer < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  scope_tag :destructive

  class << self
    def name
      "unmatch_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Unlinks a transfer (or a card or loan payment) between two of the
        family's accounts, so its two transactions count as ordinary income and
        spending again. Use it to undo a wrong match; the transactions are kept
        and can then be matched with the right counterparts.

        Pass the id of either transaction in the transfer, or the transfer_id.
        Works on confirmed and pending transfers.

        By default the pairing is recorded as rejected, so auto-match never
        suggests it again, and fee transactions of the transfer stay as plain
        expenses. reject: false only unlinks, and deletes the fee transactions
        (listed in the result). Pass dry_run: true to see the effect first.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        transaction_id: {
          type: "string",
          description: "Id of either transaction in the transfer, from get_transactions. Omit when passing transfer_id."
        },
        transfer_id: {
          type: "string",
          description: "Transfer id. Omit when passing transaction_id."
        },
        reject: {
          type: "boolean",
          description: "Also stop auto-match from suggesting this pairing again (default true)."
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

  def audit_before(params)
    transfer = lookup(params)
    transfer && serialize_transfer(transfer)
  end

  def call(params = {})
    if params["transaction_id"].present? == params["transfer_id"].present?
      return tool_error("invalid_arguments", "Pass exactly one of transaction_id or transfer_id.")
    end

    transfer = lookup(params)
    return tool_error("not_found", "No transfer for that id. get_transfer_match_candidates shows a transaction's transfer.") unless transfer

    # Only an explicit false skips the rejection; null counts as omitted
    reject = boolean_param(params, "reject", default: true)

    if boolean_param(params, "dry_run", default: false)
      snapshot = serialize_transfer(transfer)
      return {
        dry_run: true,
        reject: reject,
        transfer: snapshot,
        deletes_fee_transaction_ids: reject ? [] : snapshot[:fee_transaction_ids],
        message: "Would unlink #{snapshot[:name]}."
      }
    end

    # Locked and found again, so two calls cannot both act on the transfer and a fee attached meanwhile is reported
    snapshot = nil
    unmatched = Transfer.uncached do
      Transfer.transaction do
        locked = family_transfers.lock.find_by(id: transfer.id)
        next false unless locked

        snapshot = serialize_transfer(locked)
        reject ? locked.reject! : locked.destroy!
        true
      end
    end
    return tool_error("not_found", "The transfer was already unlinked.") unless unmatched

    ids = [ snapshot[:outflow][:transaction_id], snapshot[:inflow][:transaction_id] ]
    kinds = Transaction.where(id: ids).pluck(:id, :kind).to_h

    {
      transfer_id: snapshot[:transfer_id],
      ids: ids,
      unmatched: true,
      rejected: reject,
      transfer: snapshot,
      kinds_after: kinds,
      deleted_fee_transaction_ids: reject ? [] : snapshot[:fee_transaction_ids],
      message: "Unlinked #{snapshot[:name]}. The outflow is now #{kinds[ids.first]}, the inflow #{kinds[ids.last]}."
    }
  end

  private
    def lookup(params)
      params["transfer_id"].present? ? find_transfer(params["transfer_id"]) : find_transfer_for_transaction(params["transaction_id"])
    end
end
