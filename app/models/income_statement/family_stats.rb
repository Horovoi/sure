class IncomeStatement::FamilyStats
  def initialize(family, interval: "month", exclude_current_period: false)
    @family = family
    @interval = interval
    @exclude_current_period = exclude_current_period
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
          exclude_current_period: (@exclude_current_period ? 1 : 0)
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
            CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
            SUM(ae.amount * COALESCE(er.rate, 1)) as total
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE a.family_id = :family_id
            AND t.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
            AND ae.excluded = false
            AND (
              :exclude_current_period = 0 OR
              date_trunc(
                :interval,
                CASE WHEN :offset_days > 0 THEN (ae.date - make_interval(days => :offset_days)) ELSE ae.date END
              ) < date_trunc(
                :interval,
                CASE WHEN :offset_days > 0 THEN (CURRENT_DATE - make_interval(days => :offset_days)) ELSE CURRENT_DATE END
              )
            )
          GROUP BY period, CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
        )
        SELECT
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          ABS(AVG(total)) as avg
        FROM period_totals
        GROUP BY classification;
      SQL
    end

    def fiscal_offset_days
      return 0 unless @family.respond_to?(:fiscal_month_enabled?)
      return 0 unless @family.fiscal_month_enabled?
      day = @family.fiscal_start_day.to_i
      return 0 if day <= 1
      day - 1
    end
end
