class IncomeStatement::CategoryStats
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
        category_id: row["category_id"],
        classification: row["classification"],
        median: row["median"],
        avg: row["avg"]
      )
    end
  end

  private
    StatRow = Data.define(:category_id, :classification, :median, :avg)

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
        WITH base AS (
          SELECT
            c.id as category_id,
            c.parent_id as parent_category_id,
            date_trunc(
              :interval,
              CASE WHEN :offset_days > 0 THEN (ae.date - make_interval(days => :offset_days)) ELSE ae.date END
            ) as period,
            #{classification_sql} as classification,
            SUM(CASE WHEN t.kind = 'investment_contribution' THEN ABS(ae.amount * #{rate_sql}) ELSE ae.amount * #{rate_sql} END) as total
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN categories c ON c.id = t.category_id
          WHERE a.family_id = :family_id
            AND #{Account.visible_status_sql("a")}
            AND #{Account.included_in_reports_sql("a")}
            AND t.kind NOT IN (#{Transaction.budget_excluded_kinds_sql})
            AND ae.excluded = false
            AND (
              :exclude_current_period = 0 OR
              date_trunc(
                :interval,
                CASE WHEN :offset_days > 0 THEN (ae.date - make_interval(days => :offset_days)) ELSE ae.date END
              ) < #{current_period_sql}
            )
          GROUP BY c.id, c.parent_id, period, #{classification_sql}
        ),
        parents AS (
          SELECT
            COALESCE(parent_category_id, category_id) as category_id,
            period,
            classification,
            SUM(total) as total
          FROM base
          GROUP BY COALESCE(parent_category_id, category_id), period, classification
        ),
        final AS (
          -- Subcategory rows retain their own category_id
          SELECT b.category_id, b.period, b.classification, b.total
          FROM base b
          WHERE b.parent_category_id IS NOT NULL
          UNION ALL
          -- Parent rows roll up their own + children
          SELECT p.category_id, p.period, p.classification, p.total
          FROM parents p
          WHERE p.category_id IN (
            SELECT id FROM categories WHERE family_id = :family_id AND parent_id IS NULL
          )
        ),
        -- A NULL total is a period whose only rows have no exchange rate at all (see
        -- rate_sql). It has no measurable spending, so it neither starts, ends nor counts
        -- toward a category's run of periods.
        -- last_p: the latest past period with measurable activity in the family, or the
        -- period before the current one when there is none
        bounds AS (
          SELECT COALESCE(MAX(period), #{current_period_sql} - CAST('1 ' || :interval AS interval)) AS last_p
          FROM base
          WHERE period < #{current_period_sql} AND total IS NOT NULL
        ),
        -- start_p: the category's first period with measurable spending
        -- end_p: its latest one, or last_p when that is later
        windowed AS (
          SELECT final.*,
            MIN(period) FILTER (WHERE total IS NOT NULL) OVER (PARTITION BY category_id, classification) AS start_p,
            GREATEST(
              MAX(period) FILTER (WHERE total IS NOT NULL) OVER (PARTITION BY category_id, classification),
              (SELECT last_p FROM bounds)
            ) AS end_p
          FROM final
        )
        SELECT
          category_id,
          classification,
          -- The median stays the typical period with spending (PERCENTILE_CONT skips NULLs)
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          -- The average runs over every period from start_p to end_p, at most 12, so a
          -- period without spending counts as zero. The unfinished current period counts
          -- only once it has spending. A period with nothing convertible is left out of
          -- the count, and a category with no measurable period has no average.
          CASE WHEN MAX(start_p) IS NOT NULL THEN
            ABS(COALESCE(SUM(total) FILTER (WHERE period > end_p - CAST('12 ' || :interval AS interval)), 0) / NULLIF((
              SELECT COUNT(*) FROM generate_series(
                GREATEST(MAX(start_p), MAX(end_p) - CAST('11 ' || :interval AS interval)),
                MAX(end_p),
                CAST('1 ' || :interval AS interval)
              )
            ) - COUNT(*) FILTER (
              WHERE total IS NULL AND period > start_p AND period <= end_p
                AND period > end_p - CAST('12 ' || :interval AS interval)
            ), 0))
          END as avg
        FROM windowed
        GROUP BY category_id, classification;
      SQL
    end

    # The period that contains today, shifted like the entry periods for fiscal months
    def current_period_sql
      <<~SQL.squish
        date_trunc(
          :interval,
          CASE WHEN :offset_days > 0 THEN (CAST(:today AS date) - make_interval(days => :offset_days)) ELSE CAST(:today AS date) END
        )
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
