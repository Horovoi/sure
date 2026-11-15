# Net spending per category for a period, compared with what is normal for that
# category. Feeds the "Spending vs normal" section of Reports.
#
# Net means expense minus refunds in the same category, netted the way the cash flow
# Sankey nets them (IncomeStatement::CategoryNetting), so a refunded purchase does not
# count as spending. The totals come from IncomeStatement, so the kinds budgets leave
# out (Transaction::BUDGET_EXCLUDED_KINDS), excluded entries and pending transactions
# stay out here too.
#
# Normal (decision 39):
# - A finished period compares with the year before it (12 fiscal months when fiscal
#   months are on, since a period that starts on a fiscal boundary moves back a year to
#   the same boundary), scaled to the period's length.
# - A period that runs up to today compares the same number of days so far with the
#   same days of each earlier period start in that year (12 months back for a monthly
#   report, fiscal month starts when fiscal months are on). So a bill paid on the 1st
#   counts the same on both sides, and early-month spending is not measured against a
#   whole month.
class IncomeStatement::SpendingComparison
  BASELINE_LENGTH = 1.year
  # Below this much history before the period there is nothing meaningful to compare
  # with, so normal is nil
  MIN_BASELINE_DAYS = 28
  # Changes smaller than this (in the family currency) are left out of the change list
  MIN_CHANGE = 1

  # direct: a parent's own spending (booked on the parent, not on a subcategory),
  # listed among its subcategories
  Row = Data.define(:category, :total, :normal, :subcategories, :direct) do
    def change
      normal && total - normal
    end

    # Fractional change against normal (0.5 = 50% more); nil without a positive normal
    def ratio
      return nil unless normal&.positive?

      (total - normal) / normal
    end
  end

  attr_reader :period, :baseline_period

  # The first transaction these totals could count, filtered the way
  # IncomeStatement::Totals filters. An opening balance, an early transfer or an
  # excluded entry can come years before real spending and would dilute normal with
  # empty months.
  def self.history_start(family)
    family.transactions
      .visible
      .excluding_pending
      .where(entries: { excluded: false })
      .where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
      .minimum("entries.date")
  end

  # step_months: how far apart the period starts of the report's period type are (1 for
  # monthly, 3 for quarterly, 6 for half years, 12 for a year). Used only for a period
  # that runs up to today.
  def initialize(income_statement, period:, history_start:, step_months: 1, as_of: Date.current)
    @income_statement = income_statement
    @step_months = step_months.to_i.clamp(1, 12)
    @in_progress = period.start_date <= as_of && as_of <= period.end_date
    # A period that runs up to today counts spending so far
    @period = @in_progress ? Period.custom(start_date: period.start_date, end_date: as_of) : period
    @baseline_period = build_baseline_period(history_start)
  end

  def family
    income_statement.family
  end

  def in_progress?
    @in_progress
  end

  def comparable?
    baseline_period.present? && (!in_progress? || baseline_windows.any?)
  end

  # Parent categories (and Uncategorized) with net spending in the period or a normal
  # above zero, largest first. A parent's subcategories include one row for spending
  # booked on the parent itself, so the subcategory totals add up to the parent.
  def rows
    @rows ||= begin
      current = net_by_category(period)
      baseline = comparable? ? baseline_net : {}

      parents = (current.values + baseline.values).map { |entry| entry[:category] }
        .reject(&:subcategory?)
        .uniq { |category| key_for(category) }

      parents.filter_map { |parent| build_row(parent, current, baseline) }.sort_by { |row| -row.total }
    end
  end

  def total
    rows.sum(&:total)
  end

  def normal_total
    comparable? ? rows.sum { |row| row.normal || 0 } : nil
  end

  # Parent rows that moved by at least MIN_CHANGE against normal, the largest increase
  # first. Empty without a normal.
  def changes
    rows.select { |row| row.change && row.change.abs >= MIN_CHANGE }.sort_by { |row| -row.change }
  end

  # Rows the treemap draws: positive totals only, at both levels
  def drawable_rows
    rows.select { |row| row.total.positive? }.map do |row|
      row.with(subcategories: row.subcategories.select { |sub| sub.total.positive? })
    end
  end

  private
    attr_reader :income_statement, :step_months

    def build_baseline_period(history_start)
      end_date = period.start_date - 1.day
      start_date = [ period.start_date - BASELINE_LENGTH, history_start || period.start_date ].max
      return nil if (end_date - start_date).to_i + 1 < MIN_BASELINE_DAYS

      Period.custom(start_date: start_date, end_date: end_date)
    end

    def build_row(parent, current, baseline)
      key = key_for(parent)
      children = (current.values + baseline.values).map { |entry| entry[:category] }
        .select { |category| category.subcategory? && category.parent_id == parent.id }
        .uniq(&:id)

      total = positive(current.dig(key, :net))
      normal = scaled_normal(baseline.dig(key, :net))
      return nil if total.zero? && !normal&.positive?

      subcategories = children.filter_map do |child|
        child_key = key_for(child)
        child_total = positive(current.dig(child_key, :net))
        child_normal = scaled_normal(baseline.dig(child_key, :net))
        next if child_total.zero? && !child_normal&.positive?

        Row.new(category: child, total: child_total, normal: child_normal, subcategories: [], direct: false)
      end

      # Refunds can push a subcategory's net below zero, which lowers the parent total
      # but is clamped out of the subcategories. When the rest then add up to more than
      # the parent, the parent shows as one box, so the treemap never overstates it.
      subcategories = [] if subcategories.sum(&:total) > total

      direct_total = [ total - subcategories.sum(&:total), 0 ].max
      direct_normal = normal && [ normal - subcategories.sum { |sub| sub.normal || 0 }, 0 ].max
      if subcategories.any? && (direct_total.positive? || direct_normal&.positive?)
        subcategories << Row.new(category: parent, total: direct_total, normal: direct_normal, subcategories: [], direct: true)
      end

      Row.new(category: parent, total: total, normal: normal, subcategories: subcategories.sort_by { |sub| -sub.total }, direct: false)
    end

    # { key => { category:, net: } } for every category with activity in the period.
    # net is expense minus income booked to the category, netted per category by
    # CategoryNetting; a parent's net includes its subcategories.
    def net_by_category(net_period)
      @net_by_category ||= {}
      @net_by_category[[ net_period.start_date, net_period.end_date ]] ||=
        IncomeStatement::CategoryNetting.new(income_statement, period: net_period).groups.each_with_object({}) do |group, result|
          root_net = group[:direct] + group[:children].sum { |child| child[:net] }
          next if root_net.zero? && group[:children].all? { |child| child[:net].zero? }

          result[key_for(group[:category])] = { category: group[:category], net: root_net }
          group[:children].each do |child|
            next if child[:net].zero?

            result[key_for(child[:category])] = { category: child[:category], net: child[:net] }
          end
        end
    end

    def scaled_normal(baseline_net)
      return nil unless comparable?
      # Already an average of windows as long as the period
      return positive(baseline_net) if in_progress?

      positive(baseline_net) * period_days / baseline_days
    end

    def baseline_net
      return net_by_category(baseline_period) unless in_progress?

      windows = baseline_windows
      windows.map { |window| net_by_category(window) }.each_with_object({}) do |net, average|
        net.each do |key, entry|
          (average[key] ||= { category: entry[:category], net: 0 })[:net] += entry[:net] / windows.size
        end
      end
    end

    # The same number of days from each earlier period start within the baseline year.
    # A window that runs into the period would count the spending it is compared with,
    # so it is left out.
    def baseline_windows
      @baseline_windows ||= begin
        return [] unless baseline_period

        (1..(12 / step_months)).filter_map do |i|
          start = period_start_back(i * step_months)
          finish = start + (period_days - 1).days
          next unless start >= baseline_period.start_date && finish <= baseline_period.end_date

          Period.custom(start_date: start, end_date: finish)
        end
      end
    end

    # The period start the given number of months back. A period that starts on a fiscal
    # month boundary steps back by fiscal months, which keeps a start day clamped to a
    # short month (31 in a 30-day month) on each month's own boundary.
    def period_start_back(months)
      start = period.start_date
      if family.fiscal_month_enabled? && family.budget_period_start_for(start) == start
        month = start.beginning_of_month << months
        Date.new(month.year, month.month, [ family.fiscal_start_day, month.end_of_month.day ].min)
      else
        start << months
      end
    end

    def period_days
      (period.end_date - period.start_date).to_i + 1
    end

    def baseline_days
      (baseline_period.end_date - baseline_period.start_date).to_i + 1
    end

    def positive(value)
      [ (value || 0).to_d, 0 ].max
    end

    def key_for(category)
      IncomeStatement::CategoryNetting.key(category)
    end
end
