class DebtFlowStatement
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def period_totals(period:)
    accounts = debt_accounts
    return empty_totals if accounts.empty?

    start_date = period.date_range.begin
    end_date = period.date_range.end

    breakdowns = accounts.filter_map do |account|
      start_bal = balance_on(account, start_date)
      end_bal = balance_on(account, end_date)
      change = end_bal - start_bal

      next if change.zero?

      rate = exchange_rate(account.currency, end_date)
      converted_change = (change * rate).round(2)

      AccountBreakdown.new(
        account: account,
        change: Money.new(converted_change, family.currency)
      )
    end

    total_change = breakdowns.sum { |b| b.change.amount }
    total_paydown = breakdowns.select { |b| b.change.amount < 0 }.sum { |b| b.change.amount.abs }
    total_new_debt = breakdowns.select { |b| b.change.amount > 0 }.sum { |b| b.change.amount }

    PeriodTotals.new(
      debt_change: Money.new(total_change, family.currency),
      paydown: Money.new(total_paydown, family.currency),
      new_debt: Money.new(total_new_debt, family.currency),
      account_breakdowns: breakdowns
    )
  end

  private
    PeriodTotals = Data.define(:debt_change, :paydown, :new_debt, :account_breakdowns)
    AccountBreakdown = Data.define(:account, :change)

    def debt_accounts
      family.accounts.visible.liabilities.where(accountable_type: %w[CreditCard OtherLiability])
    end

    def balance_on(account, date)
      account.balances.where("date <= ?", date).order(date: :desc).limit(1).pick(:balance) || 0
    end

    def exchange_rate(currency, date)
      return 1.0 if currency == family.currency
      ExchangeRate.find_by(date: date, from_currency: currency, to_currency: family.currency)&.rate || 1.0
    end

    def empty_totals
      zero = Money.new(0, family.currency)
      PeriodTotals.new(debt_change: zero, paydown: zero, new_debt: zero, account_breakdowns: [])
    end
end
