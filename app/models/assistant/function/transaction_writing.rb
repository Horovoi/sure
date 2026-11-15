# Shared by create_transaction, update_transaction and delete_transaction: finding a transaction the tools may
# change, checking the ids a call names, and the shapes they return and audit. Every write follows the UI
# controllers (TransactionsController): the same lock and user-modified marks, and the same account sync.
module Assistant::Function::TransactionWriting
  # The kinds a user may set (TransactionsController::USER_SETTABLE_KINDS). Transfer kinds have one writer,
  # Transfer, so no tool sets them.
  SETTABLE_KINDS = %w[standard one_time].freeze

  # Provenance of an entry a tool created; Entry#linked? does not treat it as a bank-linked entry
  ENTRY_SOURCE = "mcp".freeze

  MAX_NAME_LENGTH = 255

  private
    # A transaction on one of the family's visible accounts, or nil (an unknown id, another family's, or a
    # malformed one all read the same)
    def find_writable_transaction(id)
      return unless valid_uuid?(id)

      family.transactions
        .joins(entry: :account)
        .merge(Account.visible)
        .includes(:category, :merchant, :tags, entry: :account)
        .find_by(id: id)
    end

    def find_writable_account(id)
      return unless valid_uuid?(id)

      family.accounts.visible.find_by(id: id)
    end

    # Returns [value, error]: nil clears, a valid id of the family's category sets, anything else is an error
    def resolve_category_id(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if valid_uuid?(value) && family.categories.exists?(id: value)

      [ nil, tool_error("invalid_category", "category_id must be an id from get_categories, or null to clear it.") ]
    end

    def resolve_merchant_id(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if valid_uuid?(value) && family.available_merchants.exists?(id: value)

      [ nil, tool_error("invalid_merchant", "merchant_id must be an id from get_merchants, or null to clear it.") ]
    end

    def resolve_tag_ids(value)
      ids = Array(value).map(&:to_s).compact_blank.uniq
      return [ [], nil ] if ids.empty?
      return [ ids, nil ] if ids.all? { |id| valid_uuid?(id) } && family.tags.where(id: ids).count == ids.size

      [ nil, tool_error("invalid_tags", "Every tag_ids entry must be an id from get_tags. Pass [] to clear the tags.") ]
    end

    def resolve_kind(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if SETTABLE_KINDS.include?(value)

      [ nil, tool_error("invalid_kind", "kind must be one of #{SETTABLE_KINDS.join(", ")}. Transfers are made with the transfer tools.") ]
    end

    # One side of a Transfer (an investment contribution included) or a row with a transfer kind. Transfer is the
    # only writer of its legs' kinds, and its legs move together.
    def transfer_leg?(transaction)
      transaction.transfer? || transaction.transfer.present?
    end

    # A calendar date in the family time zone, not after today and not before the oldest supported date
    def parse_entry_date(value)
      date = Date.iso8601(value.to_s)
      return if date > Date.current || date <= Entry.min_supported_date

      date
    rescue Date::Error, TypeError
      nil
    end

    # A finite number, never a boolean (BigDecimal accepts "NaN" and "Infinity")
    def parse_amount(value)
      return if value.nil? || value == true || value == false

      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end

    # Positive is money out (an expense), negative is money in (income), as everywhere in the app. With a nature,
    # the amount is a magnitude and the nature sets the sign.
    def signed_amount(amount, nature)
      case nature.to_s
      when "income", "inflow" then -amount.abs
      when "expense", "outflow" then amount.abs
      else amount
      end
    end

    def valid_currency?(code)
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      false
    end

    # The fields a revert needs, for the audit (before) and the result (after)
    def transaction_snapshot(transaction)
      entry = transaction.entry

      {
        id: transaction.id,
        entry_id: entry.id,
        account_id: entry.account_id,
        account: entry.account.name,
        date: entry.date.iso8601,
        name: entry.name,
        amount: entry.amount.to_s("F"),
        currency: entry.currency,
        notes: entry.notes,
        kind: transaction.kind,
        category_id: transaction.category_id,
        category: transaction.category&.name,
        merchant_id: transaction.merchant_id,
        merchant: transaction.merchant&.name,
        tag_ids: transaction.tags.map(&:id),
        excluded: entry.excluded?
      }
    end

    # Queued after the write committed. A failed enqueue must not read as a failed write (a retry without
    # external_id would create a duplicate), so it becomes a warning and the next sync recalculates.
    #
    # An update passes window_start_date, the earlier of the old and new dates, taken before the save: the
    # user-modified mark saves the entry again, after which Entry#sync_account_later no longer sees the old date
    # and a transaction moved later would leave the balances between the two dates stale.
    def sync_account_after_write(entry, window_start_date: nil)
      if window_start_date
        entry.account.sync_later(window_start_date: window_start_date)
      else
        entry.sync_account_later
      end
      nil
    rescue StandardError => e
      Rails.logger.error("Assistant tool #{name}: account sync could not be queued: #{e.class}: #{e.message}")
      "The change is saved, but the balance recalculation could not be queued; it runs on the next sync."
    end
end
