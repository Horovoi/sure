# Flags top-level categories whose spending so far this fiscal month is well above or
# below normal. Built on IncomeStatement::SpendingComparison, the same comparison the
# "Spending vs normal" report shows, so the feed and the report agree: net spending
# (refunds netted per category) from the period start to today, against the same
# number of days from each earlier period start in the year before.
#
# Upstream projected the month from its pace and compared with a 3-month average. The
# to-date comparison needs no projection, so a bill paid on the 1st does not look like
# an anomaly on the 2nd.
class Insight::Generators::SpendingAnomalyGenerator < Insight::Generator
  produces "spending_anomaly"

  MIN_ELAPSED_DAYS = 7          # too early in the period is too noisy
  DEVIATION_THRESHOLD_PCT = 25
  HIGH_PRIORITY_PCT = 50
  # A category whose normal is under this share of all normal spending is too small to flag
  MIN_NORMAL_SHARE = BigDecimal("0.03")
  MAX_INSIGHTS = 3

  def generate
    return [] if elapsed_days < MIN_ELAPSED_DAYS

    comparison = IncomeStatement::SpendingComparison.new(
      income_statement,
      period: current_period_to_date,
      history_start: IncomeStatement::SpendingComparison.history_start(family),
      step_months: 1
    )
    return [] unless comparison.comparable?

    normal_total = comparison.normal_total.to_d
    return [] unless normal_total.positive?

    anomalies = comparison.rows.filter_map do |row|
      # Synthetic rows (Uncategorized) are too mixed to name as a trend
      next unless row.category.persisted?
      next unless row.normal&.positive? && row.normal >= normal_total * MIN_NORMAL_SHARE

      deviation_pct = row.ratio * 100
      next if deviation_pct.abs < DEVIATION_THRESHOLD_PCT

      { row: row, deviation_pct: deviation_pct }
    end

    anomalies.sort_by { |anomaly| [ -anomaly[:deviation_pct].abs, anomaly[:row].category.id ] }
      .first(MAX_INSIGHTS)
      .map { |anomaly| anomaly_insight(anomaly) }
  end

  private
    def anomaly_insight(anomaly)
      row = anomaly[:row]
      direction = anomaly[:deviation_pct].positive? ? "above" : "below"
      deviation = round(anomaly[:deviation_pct].abs, 0).to_i

      build_insight(
        kind: "spending_anomaly",
        priority: deviation >= HIGH_PRIORITY_PCT ? "high" : "medium",
        template_key: "spending_anomaly.#{direction}",
        facts: {
          category: row.category.name,
          deviation_pct: deviation,
          spent: format_money(row.total),
          normal: format_money(row.normal),
          days: elapsed_days
        },
        # Spending accrues every day, so exact amounts would read as a change nightly.
        # The deviation in steps of 25 points is the material part.
        metadata: {
          category_id: row.category.id,
          category_filter: row.category.filter_value,
          direction: direction,
          deviation_bucket: (deviation / 25) * 25
        },
        period_start: current_period_start,
        dedupe_key: row.category.id
      )
    end
end
