# Creates a transaction the way the New transaction form does (TransactionsController#create): an Entry with a
# Transaction, its attributes locked, then the account sync. With an external_id the call is idempotent: a repeat
# returns the transaction the first call made. Hand port of upstream ab457b473, without sharing scopes.
class Assistant::Function::CreateTransaction < Assistant::Function
  include Assistant::Function::TransactionWriting

  scope_tag :write

  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Creates a transaction on one of the user's accounts (all accounts are entered by hand).

        Amount sign: a positive amount is money out (an expense), a negative
        amount is money in (income). Or pass a positive amount and `nature`
        ("expense" or "income"), which then sets the sign.

        date is a calendar date (YYYY-MM-DD) in the family time zone, today or
        earlier. account_id comes from get_accounts, category_id from
        get_categories, merchant_id from get_merchants, tag_ids from get_tags.
        The currency defaults to the account's.

        Pass `external_id` (a stable key such as a statement row number) to make
        the call safe to retry: a repeat with the same account and external_id
        returns the existing transaction with created: false instead of adding a
        duplicate. Transfers between the user's own accounts are not made here.

        Example:

        ```
        create_transaction({
          account_id: "abc123-...",
          date: "#{Date.current}",
          amount: 250,
          nature: "expense",
          name: "Silpo",
          category_id: "def456-..."
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id date amount name],
      properties: {
        account_id: { type: "string", description: "Account id from get_accounts" },
        date: { type: "string", description: "Date (YYYY-MM-DD), today or earlier, in the family time zone" },
        amount: { type: "number", description: "Positive is money out, negative is money in; with nature, a magnitude" },
        name: { type: "string", description: "Description or payee, as the user would write it" },
        nature: {
          type: "string",
          enum: %w[expense income],
          description: "Optional. Sets the sign: expense is money out, income is money in"
        },
        currency: { type: "string", description: "ISO 4217 code. Defaults to the account's currency" },
        notes: { type: [ "string", "null" ], description: "Optional notes" },
        category_id: { type: [ "string", "null" ], description: "Category id from get_categories" },
        merchant_id: { type: [ "string", "null" ], description: "Merchant id from get_merchants" },
        tag_ids: { type: "array", items: { type: "string" }, description: "Tag ids from get_tags" },
        kind: {
          type: "string",
          enum: SETTABLE_KINDS,
          description: "standard (default) or one_time (left out of budgets and income statements)"
        },
        external_id: {
          type: "string",
          description: "Optional idempotency key. A repeat with the same account and external_id returns the existing transaction"
        }
      }
    )
  end

  def record_type
    "Transaction"
  end

  def call(params = {})
    account = find_writable_account(params["account_id"])
    return tool_error("account_not_found", "Use an account id from get_accounts.") unless account

    external_id = params["external_id"].to_s.strip.presence
    if external_id && (existing = existing_entry(account, external_id))
      return existing_result(existing)
    end

    attributes, error = entry_attributes(account, params)
    return error if error

    entry = account.entries.new(attributes)
    entry.external_id = external_id
    entry.source = ENTRY_SOURCE

    begin
      entry.save!
    rescue ActiveRecord::RecordNotUnique
      # A concurrent call with the same key won the unique index
      existing = external_id && existing_entry(account, external_id)
      return existing_result(existing) if existing

      raise
    end

    entry.lock_saved_attributes!
    entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
    warning = sync_account_after_write(entry)

    { id: entry.transaction.id, entry_id: entry.id, created: true, transaction: transaction_snapshot(entry.transaction), warning: warning }.compact
  end

  private
    def entry_attributes(account, params)
      date = parse_entry_date(params["date"])
      return [ nil, tool_error("invalid_date", "date must be YYYY-MM-DD, today (#{Date.current}) or earlier.") ] unless date

      amount = parse_amount(params["amount"])
      return [ nil, tool_error("invalid_amount", "amount must be a number.") ] unless amount

      name = params["name"].to_s.squish
      return [ nil, tool_error("invalid_name", "name is required (at most #{MAX_NAME_LENGTH} characters).") ] if name.empty? || name.length > MAX_NAME_LENGTH

      currency = (params["currency"].to_s.strip.presence || account.currency).upcase
      return [ nil, tool_error("invalid_currency", "currency must be an ISO 4217 code such as UAH or USD.") ] unless valid_currency?(currency)

      category_id, error = resolve_category_id(params["category_id"])
      return [ nil, error ] if error

      merchant_id, error = resolve_merchant_id(params["merchant_id"])
      return [ nil, error ] if error

      tag_ids, error = resolve_tag_ids(params["tag_ids"])
      return [ nil, error ] if error

      kind, error = resolve_kind(params["kind"])
      return [ nil, error ] if error

      attributes = {
        date: date,
        name: name,
        amount: signed_amount(amount, params["nature"]),
        currency: currency,
        notes: params["notes"].presence,
        entryable: Transaction.new(category_id: category_id, merchant_id: merchant_id, tag_ids: tag_ids, kind: kind || "standard")
      }

      [ attributes, nil ]
    end

    def existing_entry(account, external_id)
      account.entries.find_by(source: ENTRY_SOURCE, external_id: external_id)
    end

    def existing_result(entry)
      unless entry.transaction?
        return tool_error("idempotency_conflict", "That external_id already belongs to an entry that is not a transaction; use another key.")
      end

      { id: entry.transaction.id, entry_id: entry.id, created: false, transaction: transaction_snapshot(entry.transaction) }
    end
end
