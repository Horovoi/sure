# Projects the family's cash (active Depository accounts the reports count) 30 days
# ahead: the subscriptions and recurring bills due in that window on known dates, plus
# the rest of a typical fiscal month's spending spread evenly over the days; and the
# same for money coming in: recurring income on its dates, plus the rest of a typical
# month's income spread evenly. Without the income, any household that spends more in
# a month than it holds would always be warned. Warns when the projected low point
# falls under a week of typical spending.
#
# The fork has no bills subsystem (upstream's recurring occurrences): the dates come
# from each active recurring transaction's next_expected_date, a monthly one repeating
# a month later when that still falls in the window.
class Insight::Generators::CashFlowWarningGenerator < Insight::Generator
  produces "cash_flow_warning"

  HORIZON_DAYS = 30
  # The low-balance line, as a share of the median fiscal month of spending (about a week)
  LOW_BALANCE_SHARE = BigDecimal("0.25")
  # Bucket of the low point that counts as a material change, as a share of that month
  CHANGE_BUCKET_SHARE = BigDecimal("0.1")

  def generate
    accounts = cash_accounts.to_a
    return [] if accounts.empty?

    balances = accounts.filter_map { |account| in_family_currency(account.balance_money) }
    return [] if balances.empty?

    starting_balance = balances.sum(0.to_d)
    obligations = upcoming_obligations
    monthly = median_monthly_expense
    return [] if monthly <= 0 && obligations.empty?

    # The bills are part of the monthly median too: subtract them so they are not
    # counted twice when the remainder is spread across the window
    known_total = obligations.sum(0.to_d) { |obligation| obligation[:amount] }
    other_daily_spend = [ monthly - known_total, 0.to_d ].max / HORIZON_DAYS
    by_date = obligations.group_by { |obligation| obligation[:date] }

    # Income the same way: recurring income on its dates, the rest of a typical month
    # spread over the days
    incomes = upcoming_incomes
    known_income = incomes.sum(0.to_d) { |income| income[:amount] }
    other_daily_income = [ median_monthly_income - known_income, 0.to_d ].max / HORIZON_DAYS
    incomes_by_date = incomes.group_by { |income| income[:date] }

    balance = starting_balance
    low_point = starting_balance
    low_date = Date.current

    (1..HORIZON_DAYS).each do |offset|
      date = Date.current + offset
      balance += other_daily_income - other_daily_spend
      incomes_by_date.fetch(date, []).each { |income| balance += income[:amount] }
      by_date.fetch(date, []).each { |obligation| balance -= obligation[:amount] }

      if balance < low_point
        low_point = balance
        low_date = date
      end
    end

    threshold = monthly * LOW_BALANCE_SHARE
    return [] if low_point >= threshold
    # Cash that only grows over the window is not about to run low, however small
    return [] if low_point >= starting_balance

    negative = low_point.negative?
    bucket = [ monthly * CHANGE_BUCKET_SHARE, 1 ].max

    [
      build_insight(
        kind: "cash_flow_warning",
        priority: negative ? "high" : "medium",
        template_key: negative ? "cash_flow_warning.negative" : "cash_flow_warning.low",
        facts: {
          projected_low: format_money(low_point),
          projected_low_date: I18n.l(low_date, format: :long),
          current_balance: format_money(starting_balance),
          horizon_days: HORIZON_DAYS
        },
        # Balances and dates move with nearly every transaction; only the severity and
        # a coarse bucket of the low point count as a change
        metadata: { negative: negative, projected_low_bucket: (low_point / bucket).floor.to_i },
        period_start: current_period_start,
        dedupe_key: "cash"
      )
    ]
  end

  private
    # [{ date:, amount: }] in the family currency for the active recurring expenses
    # due in the window. A charge in a currency with no rate is left out.
    def upcoming_obligations
      upcoming_recurring("amount > 0")
    end

    # The same for recurring income (a salary), as positive amounts
    def upcoming_incomes
      upcoming_recurring("amount < 0")
    end

    def upcoming_recurring(sign_condition)
      horizon = (Date.current + 1)..(Date.current + HORIZON_DAYS)

      family.recurring_transactions.active.where(sign_condition).where(next_expected_date: ..horizon.end).flat_map do |recurring|
        amount = in_family_currency(Money.new(recurring.amount_for_transaction, recurring.currency))&.abs
        next [] unless amount&.positive?

        due_dates(recurring, horizon).map { |date| { date: date, amount: amount } }
      end
    end

    # The median fiscal month of income, in the family currency
    def median_monthly_income
      @median_monthly_income ||= income_statement.median_income(interval: "month", exclude_current_period: true).to_d
    end

    def due_dates(recurring, horizon)
      date = recurring.next_expected_date
      if date < horizon.begin
        # An overdue subscription or manual bill is still owed: it counts tomorrow. A
        # detected pattern that did not recur may have stopped, so it counts no more.
        return [] unless recurring.user_managed?

        date = horizon.begin
      end
      dates = [ date ]
      dates << date.next_month if !recurring.billing_cycle_yearly? && date.next_month <= horizon.end
      dates.select { |d| horizon.cover?(d) }
    end
end
