class IncomeStatement::FamilyStats
  # today: the family's date (Date.current in its time zone). It decides which period
  # is the current one; Postgres CURRENT_DATE is the UTC date, a day off around midnight.
  def initialize(family, interval: "month", exclude_current_period: false, today: Date.current)
    @family = family
    @interval = interval
    @exclude_current_period = exclude_current_period
    @today = today.to_date
  end

  def call
    ActiveRecord::Base.connection.select_all(sanitized_query_sql).map do |row|
      StatRow.new(
        classification: row["classification"],
        median: row["median"],
        avg: row["avg"]
      )
    end
  end

  private
    StatRow = Data.define(:classification, :median, :avg)

    def sanitized_query_sql
      ActiveRecord::Base.sanitize_sql_array([
        query_sql,
        {
          target_currency: @family.currency,
          interval: @interval,
          family_id: @family.id,
          offset_days: fiscal_offset_days,
          exclude_current_period: (@exclude_current_period ? 1 : 0),
          today: @today
        }
      ])
    end

    def query_sql
      <<~SQL
        WITH period_totals AS (
          SELECT
            date_trunc(
              :interval,
              CASE WHEN :offset_days > 0 THEN (ae.date - make_interval(days => :offset_days)) ELSE ae.date END
            ) as period,
            #{classification_sql} as classification,
            SUM(CASE WHEN t.kind = 'investment_contribution' THEN ABS(ae.amount * #{rate_sql}) ELSE ae.amount * #{rate_sql} END) as total
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          WHERE a.family_id = :family_id
            AND #{Account.visible_status_sql("a")}
            AND t.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
            AND ae.excluded = false
            AND (
              :exclude_current_period = 0 OR
              date_trunc(
                :interval,
                CASE WHEN :offset_days > 0 THEN (ae.date - make_interval(days => :offset_days)) ELSE ae.date END
              ) < date_trunc(
                :interval,
                CASE WHEN :offset_days > 0 THEN (CAST(:today AS date) - make_interval(days => :offset_days)) ELSE CAST(:today AS date) END
              )
            )
          GROUP BY period, #{classification_sql}
        )
        SELECT
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          ABS(AVG(total)) as avg
        FROM period_totals
        GROUP BY classification;
      SQL
    end

    # The nearest stored rate of the entry's day. NULL when its currency has no rate at all:
    # the amount drops out of the SUM, and a period with nothing convertible has a NULL total.
    def rate_sql
      ExchangeRate.rate_sql(from: "ae.currency", to: ":target_currency", on: "ae.date")
    end

    # Same as IncomeStatement::Totals: an investment contribution is an expense whatever
    # its sign (a provider may import a payroll contribution as an inflow)
    def classification_sql
      "CASE WHEN t.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END"
    end

    def fiscal_offset_days
      return 0 unless @family.respond_to?(:fiscal_month_enabled?)
      return 0 unless @family.fiscal_month_enabled?
      day = @family.fiscal_start_day.to_i
      return 0 if day <= 1
      day - 1
    end
end
