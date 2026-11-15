# Per-day, per-category net amounts (in the family currency) for a period. Feeds the
# dashboard's cumulative spending curve (IncomeStatement::SpendingTrend).
#
# Scoped like IncomeStatement::Totals: the kinds budgets leave out
# (Transaction::BUDGET_EXCLUDED_KINDS), internal investment movements, excluded entries
# and hidden accounts stay out, and each entry converts at the nearest stored rate of
# its day (an entry whose currency has no rate at all is left out, never counted at 1).
#
# A row is signed, positive meaning spending: a refund in a category is a negative
# amount on its own day. Investment contributions always count as spending
# (decision 29). IncomeStatement#daily_expense_series decides which categories are
# spending by netting each one over the period, as IncomeStatement::CategoryNetting does.
class IncomeStatement::DailyExpenseTotals
  Row = Data.define(:date, :category_id, :amount)

  def initialize(family, transactions_scope:, date_range:)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range

    validate_date_range!
  end

  def call
    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      Row.new(date: row["day"].to_date, category_id: row["category_id"], amount: row["amount"].to_d)
    end
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql_body, sql_params ])
    end

    def query_sql_body
      <<~SQL
        SELECT
          ae.date AS day,
          at.category_id AS category_id,
          COALESCE(SUM(CASE WHEN at.kind = 'investment_contribution' THEN ABS(ae.amount * #{rate_sql}) ELSE ae.amount * #{rate_sql} END), 0) AS amount
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        WHERE at.kind NOT IN (#{Transaction.budget_excluded_kinds_sql})
          AND (
            at.investment_activity_label IS NULL
            OR at.investment_activity_label NOT IN ('Transfer', 'Sweep In', 'Sweep Out', 'Exchange')
          )
          AND ae.excluded = false
          AND ae.date BETWEEN :start_date AND :end_date
          AND a.family_id = :family_id
          AND #{Account.visible_status_sql("a")}
        GROUP BY ae.date, at.category_id
        ORDER BY ae.date
      SQL
    end

    # The nearest stored rate of the entry's day; NULL (left out) when its currency has none
    def rate_sql
      ExchangeRate.rate_sql(from: "ae.currency", to: ":target_currency", on: "ae.date")
    end

    def sql_params
      {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
    end

    def validate_date_range!
      unless @date_range.is_a?(Range) && @date_range.begin.respond_to?(:to_date) && @date_range.end.respond_to?(:to_date)
        raise ArgumentError, "date_range must be a Range of dates, got #{@date_range.inspect}"
      end
    end
end
