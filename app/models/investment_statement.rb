require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains

  attr_reader :family

  def initialize(family)
    @family = family
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    trades_in_period = family.trades
      .joins(:entry)
      .where(entries: { date: period.date_range })

    result = totals_query(trades_scope: trades_in_period)

    PeriodTotals.new(
      contributions: Money.new(result[:contributions], family.currency),
      withdrawals: Money.new(result[:withdrawals], family.currency),
      dividends: Money.new(result[:dividends], family.currency),
      interest: Money.new(result[:interest], family.currency),
      trades_count: result[:trades_count],
      currency: family.currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts, in the family currency
  def portfolio_value
    investment_accounts.sum { |account| to_family_money(account.balance_money).amount }
  end

  def portfolio_value_money
    Money.new(portfolio_value, family.currency)
  end

  # Total cash in investment accounts, in the family currency
  def cash_balance
    investment_accounts.sum { |account| to_family_money(account.cash_balance_money).amount }
  end

  def cash_balance_money
    Money.new(cash_balance, family.currency)
  end

  # Total holdings value
  def holdings_value
    portfolio_value - cash_balance
  end

  def holdings_value_money
    Money.new(holdings_value, family.currency)
  end

  # All current holdings across investment accounts, in their own (price) currency.
  # Sums over them go through to_family_money.
  def current_holdings
    return Holding.none unless investment_accounts.any?

    account_ids = investment_accounts.pluck(:id)

    # Get the latest holding for each security per account
    Holding
      .where(account_id: account_ids)
      .where.not(qty: 0)
      .where(
        id: Holding
          .where(account_id: account_ids)
          .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.id")
          .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
      )
      .includes(:security, :account)
      .order(amount: :desc)
  end

  # current_holdings loaded once per statement: one page computes several figures from them
  def loaded_current_holdings
    @loaded_current_holdings ||= current_holdings.to_a
  end

  # Top holdings by value in the family currency. Loaded up front: callers check `any?` and then iterate.
  def top_holdings(limit: 5)
    loaded_current_holdings.sort_by { |holding| -to_family_money(holding.amount_money).amount }.first(limit)
  end

  # Portfolio allocation by security type/sector (simplified for now)
  def allocation
    holdings = loaded_current_holdings
    total = holdings.sum { |holding| to_family_money(holding.amount_money).amount }

    return [] if total.zero?

    holdings.map do |holding|
      amount = to_family_money(holding.amount_money)

      HoldingAllocation.new(
        security: holding.security,
        amount: amount,
        weight: (amount.amount / total * 100).round(2),
        trend: holding.trend
      )
    end
  end

  # Unrealized gains across all holdings, in the family currency
  def unrealized_gains
    loaded_current_holdings.sum do |holding|
      trend = holding.trend
      trend ? to_family_money(trend.value).amount : 0
    end
  end

  # Total contributions (all time) - returns numeric for monetize
  def total_contributions
    all_time_totals.contributions&.amount || 0
  end

  # Total dividends (all time) - returns numeric for monetize
  def total_dividends
    all_time_totals.dividends&.amount || 0
  end

  # Total interest (all time) - returns numeric for monetize
  def total_interest
    all_time_totals.interest&.amount || 0
  end

  def unrealized_gains_trend
    holdings = loaded_current_holdings
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = holdings_with_cost_basis.sum { |h| to_family_money(h.amount_money).amount }
    previous = holdings_with_cost_basis.sum { |h| to_family_money(h.avg_cost * h.qty).amount }

    Trend.new(current: current, previous: previous)
  end

  # Day change across portfolio
  def day_change
    holdings = loaded_current_holdings
    changes = holdings.map(&:day_change).compact

    return nil if changes.empty?

    current = changes.sum { |t| to_family_money(t.current).amount }
    previous = changes.sum { |t| to_family_money(t.previous).amount }

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  # Converts money in any currency to the family currency at the nearest stored rate for
  # today (the latest on or before it, else the earliest after it), without calling a rate
  # provider. A currency with no rate at all converts to 0: the amount is left out of every
  # sum here rather than counted at 1, and the pages say the currency is missing.
  def to_family_money(money)
    return money if money.currency.iso_code == family.currency

    rate = rate_to_family_currency(money.currency.iso_code)
    Money.new(rate ? money.amount * rate : 0, family.currency)
  end

  # Like to_family_money, but nil when the currency has no stored rate into the family
  # currency at all, so a caller can count what it left out
  def to_family_money_or_nil(money)
    return money if money.currency.iso_code == family.currency

    rate = rate_to_family_currency(money.currency.iso_code)
    rate && Money.new(money.amount * rate, family.currency)
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= family.accounts.visible.where(accountable_type: %w[Investment Crypto])
  end

  private
    # nil when the currency has no stored rate into the family currency at all
    def rate_to_family_currency(currency)
      @rates_to_family_currency ||= {}
      return @rates_to_family_currency[currency] if @rates_to_family_currency.key?(currency)

      rate = ExchangeRate.nearest_stored_rate(from: currency, to: family.currency, date: Date.current)&.rate
      report_left_out_currency(currency) if rate.nil?
      @rates_to_family_currency[currency] = rate
    end

    def report_left_out_currency(currency)
      ExchangeRate.report_left_out_amount(
        from: currency, to: family.currency, date: Date.current, source: "InvestmentStatement", family: family
      )
    end

    def all_time_totals
      @all_time_totals ||= totals(period: Period.all_time)
    end

    PeriodTotals = Data.define(:contributions, :withdrawals, :dividends, :interest, :trades_count, :currency) do
      def net_flow
        contributions - withdrawals
      end

      def total_income
        dividends + interest
      end
    end

    HoldingAllocation = Data.define(:security, :amount, :weight, :trend)

    def totals_query(trades_scope:)
      sql_hash = Digest::MD5.hexdigest(trades_scope.to_sql)

      Rails.cache.fetch([
        "investment_statement", "totals_query", family.id, sql_hash, family.entries_cache_version,
        ExchangeRate.conversion_cache_key(family.currency)
       ], expires_in: Family::AGGREGATE_CACHE_TTL) { Totals.new(family, trades_scope: trades_scope).call }
    end

    def monetizable_currency
      family.currency
    end
end
