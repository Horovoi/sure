# Sets a manual account's balance as of today through Account#set_current_balance, the same path as the account's
# "Update balance" form: an account tracked by transactions (a cash account with no balance updates) gets its
# opening balance adjusted, any other gets a reconciliation dated today. Fork-native; the rule that a written value
# must cite its source comes from upstream's record_valuation (efb7cc393). The citation goes into the notes of the
# valuation entry that now holds the balance, after any note a person wrote there.
class Assistant::Function::RecordBalance < Assistant::Function
  scope_tag :destructive

  MIN_SOURCE_LENGTH = 3
  MAX_SOURCE_LENGTH = 500

  class << self
    def name
      "record_balance"
    end

    def description
      <<~INSTRUCTIONS
        Records today's balance of a manual account, the way the account's
        "Update balance" form does, with a citation of where the number came
        from.

        `source` is required: name the document or screen the balance was read
        from, e.g. "Monobank app, card balance screen #{Date.current}" or
        "PrivatBank statement for October". If you do not have a source, ask the
        user; never invent one.

        balance uses the sign get_accounts shows (a loan's or card's debt is
        positive). For a cash account tracked by its transactions, the opening
        balance is adjusted so today's balance matches; for any other account a
        balance update dated today is recorded (or replaced). The result says
        which entry changed.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id balance source],
      properties: {
        account_id: { type: "string", description: "Manual account id from get_accounts" },
        balance: { type: "number", description: "Today's balance in the account's currency" },
        source: { type: "string", description: "Where the balance came from (a document, statement or app screen)" }
      }
    )
  end

  def record_type
    "Account"
  end

  # The same balance and source again change nothing more
  def idempotent?
    true
  end

  def audit_before(params)
    account = find_account(params["account_id"])
    return unless account

    entry = valuation_today(account)
    {
      account_id: account.id,
      balance: account.balance.to_s("F"),
      opening: { date: account.opening_anchor_date, balance: account.opening_anchor_balance.to_d.to_s("F") },
      valuation_today: entry && { entry_id: entry.id, amount: entry.amount.to_s("F"), notes: entry.notes }
    }
  end

  def call(params = {})
    account = find_account(params["account_id"])
    return tool_error("not_found", "Use a manual account id from get_accounts.") unless account
    return tool_error("linked_account", "#{account.name} is synced from a provider, which manages its balance.") if account.linked?

    balance = parse_balance(params["balance"])
    return tool_error("invalid_balance", "balance must be a number.") unless balance

    source = params["source"].to_s.squish
    if source.length < MIN_SOURCE_LENGTH || source.length > MAX_SOURCE_LENGTH
      return tool_error(
        "source_required",
        "source must name where the balance came from (#{MIN_SOURCE_LENGTH} to #{MAX_SOURCE_LENGTH} characters). Ask the user if you do not know."
      )
    end

    previous_balance = account.balance
    result = account.set_current_balance(balance)
    return tool_error("update_failed", result.error.to_s.truncate(300)) unless result.success?

    entry = changed_valuation(account)
    entry&.update!(notes: merged_notes(entry.notes, source))

    {
      id: account.id,
      entry_id: entry&.id,
      account: { id: account.id, name: account.name, currency: account.currency },
      previous_balance: previous_balance.to_s("F"),
      balance: balance.to_s("F"),
      recorded_as: entry && (entry.entryable.opening_anchor? ? "opening_balance_adjusted" : "balance_update_today"),
      source: source
    }.compact
  end

  private
    def find_account(id)
      valid_uuid?(id) ? family.accounts.visible.find_by(id: id) : nil
    end

    def valuation_today(account)
      account.entries.where(entryable_type: "Valuation").find_by(date: Date.current)
    end

    # The valuation now holding the balance: today's reconciliation (or an opening anchor dated today), else the
    # opening anchor that set_current_balance adjusted
    def changed_valuation(account)
      valuation_today(account) ||
        account.entries
          .where(entryable_type: "Valuation")
          .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
          .where(valuations: { kind: "opening_anchor" })
          .order(:date)
          .first
    end

    # Nothing is removed: a person's note stays and the citation is added below it. The same citation again is a
    # no-op, so a repeat does not grow the note.
    def merged_notes(existing, source)
      existing = existing.to_s.strip
      return source if existing.blank?
      return existing if existing.lines.any? { |line| line.strip == source }

      [ existing, source ].join("\n\n")
    end

    def parse_balance(value)
      return if value.nil? || value == true || value == false

      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end
end
