# Compares the savings rate of the last two complete fiscal months. The current
# period is skipped on purpose: income lands early or late in a period, which makes
# a rate mid-period meaningless.
class Insight::Generators::SavingsRateChangeGenerator < Insight::Generator
  produces "savings_rate_change"

  THRESHOLD_PP = 5
  HIGH_PRIORITY_PP = 10

  def generate
    last_period = fiscal_period(back: 1)
    prior_period = fiscal_period(back: 2)

    current_rate = savings_rate(last_period)
    previous_rate = savings_rate(prior_period)
    return [] unless current_rate && previous_rate

    delta = current_rate - previous_rate
    return [] if delta.abs < THRESHOLD_PP

    direction = delta.positive? ? "up" : "down"
    # "You saved -5.4%" is machine-speak: a negative rate means more went out than came in
    template_key = direction == "down" && current_rate.negative? ? "savings_rate_change.down_negative" : "savings_rate_change.#{direction}"

    [
      build_insight(
        kind: "savings_rate_change",
        priority: delta.abs >= HIGH_PRIORITY_PP ? "high" : "medium",
        template_key: template_key,
        facts: {
          month: month_name(last_period.start_date),
          current_rate: signed_number(round(current_rate, 1)),
          previous_rate: signed_number(round(previous_rate, 1)),
          change_pp: round(delta.abs, 1)
        },
        metadata: { current_rate: round(current_rate, 1), previous_rate: round(previous_rate, 1) },
        period_start: last_period.start_date,
        dedupe_key: "rate"
      )
    ]
  end

  private
    def savings_rate(period)
      income = income_statement.income_totals(period: period).total.to_d
      return nil if income <= 0

      expense = income_statement.expense_totals(period: period).total.to_d
      (income - expense) / income * 100
    end
end
