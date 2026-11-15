# Spending and income with no category, grouped by payee, so the model can propose one category (or rule) per
# payee. Hand port of upstream's tool (efb7cc393 / 6dac776ed) on the fork's data: rows are the ones the
# Transactions page's Uncategorized filter shows (no category, not a funds movement or card payment), on visible
# accounts, not excluded and not pending. There is no bank-label normalizer, so a payee is the merchant or the
# transaction name with its case and spacing folded.
class Assistant::Function::GetUncategorizedTransactions < Assistant::Function
  MAX_PAYEES = 50
  DEFAULT_PAYEES = 20
  DEFAULT_LOOKBACK_DAYS = 180
  # The whole window is loaded to group it, so it is bounded
  MAX_LOOKBACK_DAYS = 730
  IDS_PER_PAYEE = 10

  # Transfer kinds the budget still counts as spending (the income statements leave out only funds movements,
  # card payments and one-time rows), so an uncategorized one is a real gap
  EXPENSE_KINDS = %w[loan_payment investment_contribution].freeze
  NOT_CATEGORIZABLE_KINDS = %w[funds_movement cc_payment].freeze

  class << self
    def name
      "get_uncategorized_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Lists the transactions that have no category yet, grouped by payee
        (the merchant, or the transaction name), largest total first.

        Use it before quoting a per-category total: a large uncategorized total
        means category figures are understated. Each group lists up to
        #{IDS_PER_PAYEE} transaction ids to pass to update_transaction with a
        category_id, and its own currency.

        Totals are per currency and split into expense and income, never
        netted. Every total is a positive magnitude; `classification` says the
        side. Transfers between the user's own accounts are never listed. Loan
        payments and investment contributions are, because the budget counts
        them as spending. One-time transactions are listed too; they still
        need a category even though budgets leave them out.

        `rules` says whether any active rule sets categories automatically.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        start_date: {
          type: "string",
          description: "Start date, YYYY-MM-DD (defaults to #{DEFAULT_LOOKBACK_DAYS} days ago; at most #{MAX_LOOKBACK_DAYS} days before end_date)"
        },
        end_date: { type: "string", description: "End date, YYYY-MM-DD (defaults to today)" },
        account_ids: { type: "array", items: { type: "string" }, description: "Only these account ids (from get_accounts)" },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: MAX_PAYEES,
          description: "How many payee groups to return (defaults to #{DEFAULT_PAYEES})"
        }
      }
    )
  end

  def call(params = {})
    period = resolve_period(params)
    limit = (Integer(params["limit"].to_s, exception: false) || DEFAULT_PAYEES).clamp(1, MAX_PAYEES)

    entries = uncategorized_entries(period, params["account_ids"])
    groups = group_by_payee(entries)

    {
      period: { start_date: period.first, end_date: period.last },
      transaction_count: entries.size,
      payee_count: groups.size,
      totals_by_currency: totals_by_currency(entries),
      payees: groups.first(limit).map { |group| serialize_group(group) },
      truncated: groups.size > limit,
      rules: rules_state
    }
  end

  private
    def resolve_period(params)
      end_date = parse_date(params["end_date"]) || Date.current
      start_date = parse_date(params["start_date"]) || (end_date - DEFAULT_LOOKBACK_DAYS)
      start_date = end_date if start_date > end_date
      start_date = [ start_date, end_date - MAX_LOOKBACK_DAYS ].max

      start_date..end_date
    end

    def parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def uncategorized_entries(period, account_ids)
      family.entries
        .merge(Account.visible)
        .where(account_id: account_scope(account_ids))
        .where(entryable_type: "Transaction", date: period, excluded: false)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(transactions: { category_id: nil })
        .where.not(transactions: { kind: NOT_CATEGORIZABLE_KINDS })
        .excluding_pending
        .preload(:account, entryable: :merchant)
        .to_a
    end

    # Ids that are not the family's visible accounts are ignored; none valid gives an empty result
    def account_scope(account_ids)
      accounts = family.accounts.visible
      return accounts.select(:id) if account_ids.blank?

      accounts.where(id: Array(account_ids).map(&:to_s).select { |id| valid_uuid?(id) }).select(:id)
    end

    def group_by_payee(entries)
      entries
        .group_by { |entry| payee_key(entry) }
        .map { |(payee, currency, classification), group| { payee: payee, currency: currency, classification: classification, entries: group, total: total_of(group) } }
        .sort_by { |group| [ -group[:total], group[:payee] ] }
    end

    # Currency is part of the key, so every group total is one Money
    def payee_key(entry)
      payee = entry.entryable.merchant&.name || entry.name.to_s.squish.upcase
      [ payee, entry.currency, classification_of(entry) ]
    end

    def classification_of(entry)
      return "expense" if EXPENSE_KINDS.include?(entry.entryable.kind)

      entry.amount.negative? ? "income" : "expense"
    end

    def totals_by_currency(entries)
      entries.group_by(&:currency).to_h do |currency, group|
        by_side = group.group_by { |entry| classification_of(entry) }

        [ currency, {
          expense: subtotal(by_side["expense"], currency),
          income: subtotal(by_side["income"], currency),
          transaction_count: group.size
        } ]
      end
    end

    def subtotal(entries, currency)
      entries = Array(entries)
      total = total_of(entries)

      { amount: total.to_s("F"), formatted: Money.new(total, currency).format, transaction_count: entries.size }
    end

    def serialize_group(group)
      entries = group[:entries].sort_by(&:date)

      {
        payee: group[:payee],
        currency: group[:currency],
        classification: group[:classification],
        transaction_count: entries.size,
        total_amount: group[:total].to_s("F"),
        total_amount_formatted: Money.new(group[:total], group[:currency]).format,
        first_seen: entries.first.date,
        last_seen: entries.last.date,
        accounts: entries.map { |entry| entry.account.name }.uniq,
        transaction_ids: entries.last(IDS_PER_PAYEE).reverse.map(&:entryable_id)
      }
    end

    def total_of(entries)
      entries.sum(BigDecimal("0")) { |entry| entry.amount.abs }
    end

    # Rules are the only automatic categorizer: an AI auto-categorize action or a plain set-category action
    def rules_state
      rules = family.rules.joins(:actions).where(rule_actions: { action_type: %w[auto_categorize set_transaction_category] }).distinct
      active = rules.where(active: true).count

      {
        categorizing_rules: rules.count,
        active_categorizing_rules: active,
        note: active.zero? ? "No active rule sets categories, so new transactions stay uncategorized until someone categorizes them." : nil
      }.compact
    end
end
