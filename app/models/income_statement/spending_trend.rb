# The dashboard's cumulative spending curve: one budget period (a fiscal month when
# fiscal months are on) against the period before it, on one day-of-period axis.
#
# - The axis always spans the selected period, to its last day. A longer previous
#   period folds its extra days into the last axis point, so its curve still ends at its
#   full total and the axis never rolls into the previous period's dates.
# - The selected period's curve stops at today while it runs.
# - The header compares the same days so far while the period runs (day 1 to N of both
#   periods), and the whole previous period once the selected one is over. Comparing
#   month-to-date with a complete month would show a large saving early in every month.
#
# Amounts come from IncomeStatement#daily_expense_series: refunds netted per category,
# the kinds budgets leave out excluded.
class IncomeStatement::SpendingTrend
  # start_date..end_date is the whole selected period; current stops at today while it
  # runs; previous is the whole period before it
  Periods = Data.define(:start_date, :end_date, :current, :previous)

  attr_reader :period_start, :period_end, :current_period, :previous_period, :today

  # The periods for any date of the period to show. A future period is the current one.
  def self.periods(family, date, today: Date.current)
    start_date = [ family.budget_period_start_for(date), family.budget_period_start_for(today) ].min
    end_date = family.budget_period_end_for(start_date)

    Periods.new(
      start_date: start_date,
      end_date: end_date,
      current: Period.custom(start_date: start_date, end_date: [ end_date, today ].min),
      previous: Period.custom(start_date: family.budget_period_start_for(start_date - 1), end_date: start_date - 1)
    )
  end

  # The latest `count` period starts, newest first: the options of the period picker
  def self.recent_period_starts(family, count: 12, today: Date.current)
    start = family.budget_period_start_for(today)
    Array.new(count) do
      current = start
      start = family.budget_period_start_for(start - 1)
      current
    end
  end

  # date: any date of the period to show (see .periods). category_ids: as
  # IncomeStatement#daily_expense_series takes them; nil means every category.
  def initialize(income_statement, date:, category_ids: nil, today: Date.current)
    periods = self.class.periods(income_statement.family, date, today: today)
    @today = today
    @period_start = periods.start_date
    @period_end = periods.end_date
    @current_period = periods.current
    @previous_period = periods.previous

    @current_daily = income_statement.daily_expense_series(period: @current_period, category_ids: category_ids)
    @previous_daily = income_statement.daily_expense_series(period: @previous_period, category_ids: category_ids)
  end

  def in_progress?
    today <= period_end
  end

  # Days on the axis: the whole selected period
  def axis_days
    (period_end - period_start).to_i + 1
  end

  def axis_dates
    (period_start..period_end).to_a
  end

  # One point per day ({ day:, value:, date: }), days without spending included, so flat
  # stretches stay flat
  def current_points
    @current_points ||= cumulative_points(current_period, @current_daily)
  end

  # The previous period day by day, to its last day
  def previous_points
    @previous_points ||= cumulative_points(previous_period, @previous_daily)
  end

  # The previous curve as the chart draws it. The folded last point keeps its axis slot
  # (day) but carries the true last date, so the tooltip names the day its value runs to.
  def previous_axis_points
    points = previous_points
    return points if points.size <= axis_days

    points.first(axis_days).tap do |folded|
      folded[-1] = folded[-1].merge(value: points.last[:value], date: points.last[:date])
    end
  end

  def current_total
    current_points.last&.fetch(:value) || 0.to_d
  end

  # How many days of the previous period the header compares
  def comparison_days
    in_progress? ? [ current_points.size, previous_points.size ].min : previous_points.size
  end

  def previous_total
    comparison_days.positive? ? previous_points[comparison_days - 1][:value] : 0.to_d
  end

  # True when the header compares only part of the previous period
  def partial_comparison?
    comparison_days.positive? && comparison_days < previous_points.size
  end

  # The last previous-period day the header counts
  def comparison_end_date
    previous_period.start_date + (comparison_days - 1)
  end

  def delta
    current_total - previous_total
  end

  def any_spending?
    (current_points + previous_points).any? { |point| !point[:value].zero? }
  end

  private
    def cumulative_points(period, daily)
      cumulative = 0.to_d
      period.date_range.map do |date|
        cumulative += daily.fetch(date, 0)
        { day: (date - period.start_date).to_i + 1, value: cumulative, date: date }
      end
    end
end
