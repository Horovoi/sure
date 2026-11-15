# Deletes a transaction the way the drawer's Delete does (EntryableResource#destroy): its entry is destroyed, which
# takes the transaction and any transfer link with it, then the account syncs. Hand port of upstream ab457b473,
# without sharing permissions. The audit keeps the full transaction from before, so it can be created again.
class Assistant::Function::DeleteTransaction < Assistant::Function
  include Assistant::Function::TransactionWriting

  scope_tag :destructive

  class << self
    def name
      "delete_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Permanently deletes one transaction and recalculates the account
        balance. Find the id with get_transactions. Pass account_id as well to
        guard against deleting from the wrong account: a mismatch is not_found.

        Deleting one leg of a transfer between the user's own accounts removes
        the transfer link; the other leg stays as an ordinary transaction.
        The result repeats what was deleted.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Transaction id from get_transactions" },
        account_id: { type: "string", description: "Optional guard: the account the transaction must be on" }
      }
    )
  end

  def record_type
    "Transaction"
  end

  def audit_before(params)
    transaction = find_transaction(params)
    transaction && transaction_snapshot(transaction)
  end

  def call(params = {})
    transaction = find_transaction(params)
    return tool_error("not_found", "Use a transaction id from get_transactions (and its account_id, if you pass one).") unless transaction

    entry = transaction.entry
    deleted = transaction_snapshot(transaction)

    # Entry#ensure_anchor_destroyable and the like refuse with an error rather than raising
    unless entry.destroy
      return tool_error("delete_refused", entry.errors.full_messages.to_sentence.presence || "The transaction could not be deleted.")
    end

    warning = sync_account_after_write(entry)

    { id: deleted[:id], entry_id: deleted[:entry_id], deleted: true, transaction: deleted, warning: warning }.compact
  end

  private
    def find_transaction(params)
      transaction = find_writable_transaction(params["id"])
      return transaction if transaction.nil? || params["account_id"].blank?

      transaction if transaction.entry.account_id == params["account_id"]
    end
end
