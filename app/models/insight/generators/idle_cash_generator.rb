# Points out a sizable cash balance with no activity for a while. Low priority by
# design: a nudge, not a warning. One row per account per fiscal month, so a dismissed
# nudge stays away for the rest of the month.
#
# "Sizable" is at least one median fiscal month of the family's spending, in the
# family currency (upstream used a fixed 5,000, which is small change in hryvnias).
class Insight::Generators::IdleCashGenerator < Insight::Generator
  produces "idle_cash"

  IDLE_DAYS = 60
  MAX_INSIGHTS = 2

  def generate
    threshold = median_monthly_expense
    return [] unless threshold.positive?

    idle = idle_accounts.filter_map do |account|
      converted = in_family_currency(account.balance_money)
      [ account, converted ] if converted && converted >= threshold
    end

    # Largest first, then by id, so the pick is stable between runs
    idle.sort_by { |account, converted| [ -converted, account.id ] }.first(MAX_INSIGHTS).map do |account, converted|
      build_insight(
        kind: "idle_cash",
        priority: "low",
        template_key: "idle_cash",
        facts: {
          account: account.name,
          balance: account.balance_money.format,
          idle_days: IDLE_DAYS
        },
        # Balance bucketed to a tenth of a month of spending, so interest does not count
        metadata: { account_id: account.id, balance_bucket: (converted / [ threshold / 10, 1 ].max).floor.to_i },
        period_start: current_period_start,
        dedupe_key: account.id
      )
    end
  end

  private
    def idle_accounts
      cash_accounts
        .where("accounts.balance > 0")
        .where.not(id: Entry.where("entries.date >= ?", Date.current - IDLE_DAYS).select(:account_id))
        .to_a
    end
end
