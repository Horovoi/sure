class InvestmentFlowStatement
  include Monetizable

  attr_reader :family

  def initialize(family)
    @family = family
  end

  # Get contribution/withdrawal totals for a period, in the family currency. Accounts
  # excluded from reports are left out (w3-reports).
  def period_totals(period: Period.current_month)
    transactions = family.transactions
      .visible
      .merge(Account.included_in_reports)
      .excluding_pending
      .where(entries: { date: period.date_range })
      .where(kind: %w[standard investment_contribution])
      .where(investment_activity_label: %w[Contribution Withdrawal])

    contributions = converted_sum(transactions.where(investment_activity_label: "Contribution")).abs
    withdrawals = converted_sum(transactions.where(investment_activity_label: "Withdrawal")).abs

    PeriodTotals.new(
      contributions: Money.new(contributions, family.currency),
      withdrawals: Money.new(withdrawals, family.currency),
      net_flow: Money.new(contributions - withdrawals, family.currency)
    )
  end

  PeriodTotals = Data.define(:contributions, :withdrawals, :net_flow)

  private
    # Each entry at the nearest stored rate of its day. It used to add up the raw amounts
    # of every currency as if they were the family's; one with no rate at all is left out.
    def converted_sum(transactions)
      rate = Entry.sanitize_sql_array([
        ExchangeRate.rate_sql(from: "entries.currency", to: ":target_currency", on: "entries.date"),
        { target_currency: family.currency }
      ])

      transactions.sum(Arel.sql("COALESCE(entries.amount * #{rate}, 0)"))
    end
end
