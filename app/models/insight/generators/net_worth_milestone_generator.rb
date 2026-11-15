# Celebrates net worth crossing a round milestone during the current fiscal month:
# net worth on the day before the period started was below it, today it is at or
# above it. The milestone itself is the dedupe key and the row has no period, so a
# dismissal lasts for life; a later dip below and a new crossing make a new row only
# once the first one was cleared.
#
# Upstream's fixed dollar ladder (10,000 to 10,000,000) started too low for hryvnias.
# The fork's ladder is 1, 2.5 and 5 times each power of ten from 10,000 up, which
# reads as round numbers in any currency.
class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  produces "net_worth_milestone"

  MILESTONES = (4..10).flat_map { |exp| [ 1, 2.5, 5 ].map { |step| (step * 10**exp).to_i } }.freeze

  def generate
    start = current_period_start - 1.day
    series = balance_sheet.net_worth_series(period: Period.custom(start_date: start, end_date: Date.current))
    values = series.values
    return [] if values.size < 2

    previous = money_amount(values.first.value)
    current = money_amount(values.last.value)
    return [] if current <= previous

    milestone = MILESTONES.select { |m| previous < m && current >= m }.max
    return [] unless milestone

    [
      build_insight(
        kind: "net_worth_milestone",
        priority: "high",
        template_key: "net_worth_milestone",
        facts: {
          milestone: Money.new(milestone, family.currency).format(precision: 0),
          net_worth: format_money(current)
        },
        # The milestone alone is the signal; net worth drifts daily
        metadata: { milestone: milestone },
        period_start: nil,
        dedupe_key: milestone
      )
    ]
  end

  private
    def money_amount(value)
      (value.respond_to?(:amount) ? value.amount : value).to_d
    end
end
