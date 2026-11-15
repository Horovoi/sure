# Sets a manual account's opening balance and, optionally, its date, through Account#set_opening_anchor_balance
# (the same Account::OpeningBalanceManager path as account creation, which serializes calls per account), then
# syncs. Hand port of upstream 6b6a27e1c. dry_run reports the effect without writing.
class Assistant::Function::SetOpeningBalance < Assistant::Function
  scope_tag :destructive

  class << self
    def name
      "set_opening_balance"
    end

    def description
      <<~INSTRUCTIONS
        Sets the opening balance of a manual account and, optionally, the date
        it applies from. Use it when an account's history starts on the wrong
        date or from the wrong amount.

        balance uses the sign get_accounts shows (a loan's outstanding amount is
        positive). date must be before the account's oldest other entry; omit it
        to keep the current opening date.

        The result says whether the current balance changes: a later balance
        update (reconciliation) pins the balance from its date on, so only the
        history before it changes; otherwise the current balance moves by the
        same amount. Pass dry_run: true to see the effect without changing
        anything.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id balance],
      properties: {
        account_id: { type: "string", description: "Manual account id from get_accounts" },
        balance: { type: "number", description: "Opening balance in the account's currency" },
        date: { type: "string", description: "Date the opening balance applies from (YYYY-MM-DD), before the oldest other entry" },
        dry_run: { type: "boolean", description: "Describe the change without making it (defaults to false)" }
      }
    )
  end

  def record_type
    "Account"
  end

  # Setting the same balance and date again changes nothing more
  def idempotent?
    true
  end

  def audit_before(params)
    account = find_account(params["account_id"])
    return unless account

    { account_id: account.id, opening: opening(account), current_balance: account.balance.to_s("F") }
  end

  def call(params = {})
    account = find_account(params["account_id"])
    return tool_error("not_found", "Use a manual account id from get_accounts.") unless account
    return tool_error("linked_account", "#{account.name} is synced from a provider, which manages its balances.") if account.linked?

    balance = parse_balance(params["balance"])
    return tool_error("invalid_balance", "balance must be a number.") unless balance

    date = nil
    # A blank date is an error; only a missing (or null) date keeps the current one
    unless params["date"].nil?
      date = parse_date(params["date"])
      return tool_error("invalid_date", "date must be YYYY-MM-DD.") unless date
    end

    manager = Account::OpeningBalanceManager.new(account)
    if (message = manager.date_error(date))
      return tool_error("invalid_date", "#{message} (#{manager.oldest_entry_date}).", oldest_entry_date: manager.oldest_entry_date)
    end

    before = opening(account)
    new_date = date || before&.dig(:date) || manager.default_date
    after = { date: new_date, balance: balance.to_s("F") }
    effect = current_balance_effect(account, new_date, balance - BigDecimal(before&.dig(:balance) || "0"))

    if ActiveModel::Type::Boolean.new.cast(params["dry_run"])
      return { dry_run: true, account: account_summary(account), before: before, after: after, current_balance: effect }
    end

    result = account.set_opening_anchor_balance(balance: balance, date: date)
    return tool_error("update_failed", result.error.to_s) unless result.success?

    {
      id: account.id,
      changed: result.changes_made?,
      account: account_summary(account),
      before: before,
      after: after,
      current_balance: effect
    }
  end

  private
    def find_account(id)
      valid_uuid?(id) ? family.accounts.visible.find_by(id: id) : nil
    end

    def opening(account)
      manager = Account::OpeningBalanceManager.new(account)
      return unless manager.has_opening_anchor?

      { date: manager.opening_date, balance: manager.opening_balance.to_d.to_s("F") }
    end

    # A reconciliation after the opening date pins the balance from its date on
    def current_balance_effect(account, new_date, delta)
      pinned_by = account.entries
        .where(entryable_type: "Valuation")
        .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
        .where(valuations: { kind: "reconciliation" })
        .where("entries.date > ?", new_date)
        .minimum(:date)

      if pinned_by
        { changes: false, reason: "The balance update on #{pinned_by} pins the balance from that date, so only the history before it changes." }
      elsif delta.zero?
        { changes: false, reason: "The opening balance amount is unchanged." }
      else
        { changes: true, by: delta.to_s("F"), reason: "No later balance update, so the current balance moves by the same amount." }
      end
    end

    def account_summary(account)
      { id: account.id, name: account.name, currency: account.currency }
    end

    def parse_balance(value)
      return if value.nil? || value == true || value == false

      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
