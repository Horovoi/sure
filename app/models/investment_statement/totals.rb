class InvestmentStatement::Totals
  def initialize(family, trades_scope:)
    @family = family
    @trades_scope = trades_scope
  end

  def call
    result = ActiveRecord::Base.connection.select_one(query_sql)

    {
      contributions: result["contributions"]&.to_d || 0,
      withdrawals: result["withdrawals"]&.to_d || 0,
      dividends: 0, # Dividends come through as transactions, not trades
      interest: 0,  # Interest comes through as transactions, not trades
      trades_count: result["trades_count"]&.to_i || 0
    }
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        aggregation_sql,
        sql_params
      ])
    end

    # Aggregate trades by direction (buy vs sell)
    # Buys (qty > 0) = contributions (cash going out to buy securities)
    # Sells (qty < 0) = withdrawals (cash coming in from selling securities)
    # Each trade converts at the nearest stored rate of its day; a trade in a currency with
    # no rate at all is left out, not counted at 1.
    def aggregation_sql
      rate = ExchangeRate.rate_sql(from: "ae.currency", to: ":target_currency", on: "ae.date")

      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN t.qty > 0 THEN ABS(ae.amount * #{rate}) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN t.qty < 0 THEN ABS(ae.amount * #{rate}) ELSE 0 END), 0) as withdrawals,
          COUNT(t.id) as trades_count
        FROM (#{@trades_scope.to_sql}) t
        JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Trade'
        JOIN accounts a ON a.id = ae.account_id
        WHERE a.family_id = :family_id
          AND #{Account.visible_status_sql("a")}
          AND ae.excluded = false
      SQL
    end

    def sql_params
      {
        family_id: @family.id,
        target_currency: @family.currency
      }
    end
end
