# Changes a transaction the way its drawer does (TransactionsController#update): the changed attributes are
# locked, the entry is marked user-modified, and the account syncs from the earlier of the old and new dates.
# Hand port of upstream 5f0f5ec89, plus date, amount and kind, without sharing permissions.
class Assistant::Function::UpdateTransaction < Assistant::Function
  include Assistant::Function::TransactionWriting

  scope_tag :write

  class << self
    def name
      "update_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Changes an existing transaction. Only the fields you pass change; omit a
        field to leave it as it is.

        Find the id with get_transactions (or get_uncategorized_transactions),
        and related ids with get_categories, get_merchants and get_tags. Pass
        null to clear notes, category or merchant, and [] to clear the tags
        (tag_ids replaces the whole list).

        amount uses the app's sign (positive is money out, negative is money
        in), or a magnitude with `nature`. date, amount and nature cannot change
        on a transfer between the user's own accounts. kind is standard or
        one_time (left out of budgets and income statements).

        The result has the transaction after the change; the audit keeps the
        state before it.
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
        name: { type: "string", description: "New description" },
        date: { type: "string", description: "New date (YYYY-MM-DD), today or earlier" },
        amount: { type: "number", description: "New amount: positive is money out, negative is money in; with nature, a magnitude" },
        nature: { type: "string", enum: %w[expense income], description: "Sets the sign of amount" },
        notes: { type: [ "string", "null" ], description: "New notes; null clears them" },
        category_id: { type: [ "string", "null" ], description: "Category id from get_categories; null clears it" },
        merchant_id: { type: [ "string", "null" ], description: "Merchant id from get_merchants; null clears it" },
        tag_ids: { type: "array", items: { type: "string" }, description: "The full tag list (ids from get_tags); [] clears it" },
        kind: { type: "string", enum: SETTABLE_KINDS, description: "standard or one_time" }
      }
    )
  end

  def record_type
    "Transaction"
  end

  # Setting the same fields again changes nothing more
  def idempotent?
    true
  end

  def audit_before(params)
    transaction = find_writable_transaction(params["id"])
    transaction && transaction_snapshot(transaction)
  end

  def call(params = {})
    transaction = find_writable_transaction(params["id"])
    return tool_error("not_found", "Use a transaction id from get_transactions.") unless transaction

    entry = transaction.entry
    attributes, error = changes_for(transaction, entry, params)
    return error if error
    return tool_error("no_changes", "Pass at least one field to change.") if attributes.empty? && !params.key?("tag_ids")

    old_date = entry.date

    Entry.transaction do
      entry.update!(attributes) if attributes.any?

      if params.key?("tag_ids")
        transaction.tag_ids = @tag_ids
        transaction.save!
      end

      entry.lock_saved_attributes!
      entry.mark_user_modified!
      transaction.lock_attr!(:tag_ids) if transaction.tags.any?
    end

    warning = sync_account_after_write(entry, window_start_date: [ old_date, entry.date ].min)
    transaction.reload

    { id: transaction.id, entry_id: entry.id, updated: true, transaction: transaction_snapshot(transaction), warning: warning }.compact
  end

  private
    def changes_for(transaction, entry, params)
      attributes = {}
      entryable = { id: transaction.id }

      if params.key?("name")
        name = params["name"].to_s.squish
        return [ nil, tool_error("invalid_name", "name cannot be blank (at most #{MAX_NAME_LENGTH} characters).") ] if name.empty? || name.length > MAX_NAME_LENGTH

        attributes[:name] = name
      end

      attributes[:notes] = params["notes"].presence if params.key?("notes")

      if params.key?("date") || params.key?("amount") || params.key?("nature")
        return [ nil, tool_error("transfer_locked", "A transfer's date and amount are changed on the transfer, not on one of its legs.") ] if transfer_leg?(transaction)
      end

      if params.key?("date")
        date = parse_entry_date(params["date"])
        return [ nil, tool_error("invalid_date", "date must be YYYY-MM-DD, today (#{Date.current}) or earlier.") ] unless date

        attributes[:date] = date
      end

      if params.key?("amount") || params.key?("nature")
        amount = params.key?("amount") ? parse_amount(params["amount"]) : entry.amount
        return [ nil, tool_error("invalid_amount", "amount must be a number.") ] unless amount

        attributes[:amount] = signed_amount(amount, params["nature"])
      end

      if params.key?("category_id")
        entryable[:category_id], error = resolve_category_id(params["category_id"])
        return [ nil, error ] if error
      end

      if params.key?("merchant_id")
        entryable[:merchant_id], error = resolve_merchant_id(params["merchant_id"])
        return [ nil, error ] if error
      end

      if params["kind"].present?
        return [ nil, tool_error("transfer_locked", "A transfer's kind is set by the transfer.") ] if transfer_leg?(transaction)

        entryable[:kind], error = resolve_kind(params["kind"])
        return [ nil, error ] if error
      end

      if params.key?("tag_ids")
        @tag_ids, error = resolve_tag_ids(params["tag_ids"])
        return [ nil, error ] if error
      end

      attributes[:entryable_attributes] = entryable if entryable.size > 1
      [ attributes, nil ]
    end
end
