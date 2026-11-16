module ReportsHelper
  # Returns CSS classes for tax treatment badge styling
  def tax_treatment_badge_classes(treatment)
    case treatment.to_sym
    when :tax_exempt
      "bg-green-500/10 text-green-600 theme-dark:text-green-400"
    when :tax_deferred
      "bg-blue-500/10 text-blue-600 theme-dark:text-blue-400"
    when :tax_advantaged
      "bg-purple-500/10 text-purple-600 theme-dark:text-purple-400"
    else
      "bg-gray-500/10 text-secondary"
    end
  end

  # Generate SVG polyline points for a sparkline chart
  # Returns empty string if fewer than 2 data points (can't draw a line with 1 point)
  def sparkline_points(values, width: 60, height: 16)
    return "" if values.nil? || values.length < 2 || values.all? { |v| v.nil? || v.zero? }

    nums = values.map(&:to_f)
    max_val = nums.max
    min_val = nums.min
    range = max_val - min_val
    range = 1.0 if range.zero?

    points = nums.each_with_index.map do |val, i|
      x = (i.to_f / [ nums.length - 1, 1 ].max) * width
      y = height - ((val - min_val) / range * (height - 2)) - 1
      "#{x.round(1)},#{y.round(1)}"
    end

    points.join(" ")
  end

  # Calculate cumulative net values from trends data
  def cumulative_net_values(trends)
    return [] if trends.nil?

    running = 0
    trends.map { |t| running += t[:net].to_i; running }
  end

  # Check if trends data has enough points for sparklines (need at least 2)
  def has_sparkline_data?(trends_data)
    trends_data&.length.to_i >= 2
  end

  # --- Activity breakdown: one ranked bar list per side (income, expenses) ---

  # Rows a list shows before "N more categories"
  BREAKDOWN_TOP_ROWS = 8
  # A tail of one row is shown, not folded away behind a button of its own size
  BREAKDOWN_MIN_TAIL = 2
  # The columns every list row, the column labels and the "more" row share:
  # toggle, category and bar, amount and change, share
  BREAKDOWN_GRID = "grid-cols-[1.25rem_minmax(0,1fr)_5.5rem_3rem] gap-x-2 @md:grid-cols-[1.25rem_minmax(0,1fr)_6.5rem_3.5rem] @md:gap-x-3".freeze

  # How far a category moved against normal, smallest first. upper is the largest
  # ratio (0.5 = 50% more) that still falls in the bucket; nil means no limit. The
  # tone colours the delta: within 15% of normal stays neutral, so small moves do
  # not shout.
  SPENDING_RATIO_BUCKETS = [
    { key: "less", upper: -0.5, tone: :favorable },
    { key: "slightly_less", upper: -0.15, tone: :favorable },
    { key: "normal", upper: 0.15, tone: :neutral },
    { key: "slightly_more", upper: 0.5, tone: :unfavorable },
    { key: "more", upper: 1.0, tone: :unfavorable },
    { key: "much_more", upper: nil, tone: :unfavorable }
  ].freeze

  BREAKDOWN_TONE_CLASSES = {
    favorable: "text-success",
    neutral: "text-secondary",
    unfavorable: "text-destructive"
  }.freeze

  # The bucket of a comparison row, or nil without a normal. Spending where normal is
  # zero is new spending, so it counts as much more.
  def spending_ratio_bucket(comparison, row)
    return nil unless comparison.comparable? && row.normal

    ratio = row.ratio
    return SPENDING_RATIO_BUCKETS.last if ratio.nil? && row.total.positive?
    return SPENDING_RATIO_BUCKETS.find { |bucket| bucket[:key] == "normal" } if ratio.nil?

    SPENDING_RATIO_BUCKETS.find { |bucket| bucket[:upper].nil? || ratio <= bucket[:upper] }
  end

  # Everything one side of the breakdown draws: its rows (largest first, as sorted
  # by the controller), the scale its bars share and, for expenses with a normal to
  # compare with, each row's normal and change. Income and expenses get the same
  # shape, so one partial draws both.
  #
  # The bars of a list share one scale: the largest amount or normal in it fills the
  # track. The share column says the part of the side's total.
  def breakdown_column(groups, total:, type:, start_date:, end_date:, comparison: nil)
    # Expenses say why they have no comparison, so its absence is not a mystery
    no_normal = type == :expense && comparison.present? && !comparison.comparable?
    comparison = nil unless type == :expense && comparison&.comparable?
    days = start_date && end_date ? (end_date - start_date).to_i + 1 : nil
    rows_by_key = comparison ? comparison.rows.index_by { |row| breakdown_key(row.category) } : {}

    rows = groups.map do |group|
      compared = rows_by_key.delete(group[:category_id].to_s)
      breakdown_row(group, total: total, days: days, start_date: start_date, end_date: end_date, comparison: comparison, compared: compared)
    end

    # A category normally spent on with nothing this period still moved: it gets a
    # row at zero, after the rest, so its change is not lost
    if comparison
      rows_by_key.each_value do |compared|
        next unless compared.total.zero? && compared.normal&.positive?

        rows << breakdown_missing_row(compared, comparison: comparison)
      end
    end

    scale = rows.flat_map { |row| [ row[:amount], row[:normal], *row[:subcategories].flat_map { |sub| [ sub[:amount], sub[:normal] ] } ] }.compact.max.to_f
    rows.each do |row|
      breakdown_place_on_scale(row, scale)
      row[:subcategories].each { |sub| breakdown_place_on_scale(sub, scale) }
    end

    top = rows.size - BREAKDOWN_TOP_ROWS >= BREAKDOWN_MIN_TAIL ? rows.first(BREAKDOWN_TOP_ROWS) : rows
    tail = rows.drop(top.size)

    {
      type: type,
      rows: rows,
      top: top,
      tail: tail,
      tail_amount: tail.sum { |row| row[:amount] },
      tail_share: total.positive? ? (tail.sum { |row| row[:amount] } / total.to_f * 100).round(1) : 0,
      tail_delta: comparison && tail.any? { |row| row[:change] } ? breakdown_delta(tail.sum { |row| row[:change] || 0 }, tone: :neutral) : nil,
      total: total,
      comparison: comparison,
      no_normal: no_normal,
      transactions: groups.sum { |group| group[:count] }
    }
  end

  # The one line under a side's total. Expenses with a normal: how far the side is
  # from normal. Otherwise how many categories and transactions it holds.
  def breakdown_column_summary(column)
    comparison = column[:comparison]
    unless comparison
      return [
        t("reports.transactions_breakdown.column.categories", count: column[:rows].size),
        t("reports.transactions_breakdown.column.transactions", count: column[:transactions])
      ].join(", ")
    end

    change = comparison.total - comparison.normal_total
    timing = comparison.in_progress? ? "so_far" : "period"
    return t("reports.transactions_breakdown.vs_normal.about_#{timing}") if change.abs < IncomeStatement::SpendingComparison::MIN_CHANGE

    direction = change.negative? ? "less" : "more"
    ratio = comparison.normal_total.positive? ? change / comparison.normal_total : nil
    tone = SPENDING_RATIO_BUCKETS.find { |bucket| ratio.nil? || bucket[:upper].nil? || ratio <= bucket[:upper] }[:tone]
    amount = tag.span(breakdown_money(change.abs), class: "font-medium #{BREAKDOWN_TONE_CLASSES.fetch(tone)}")

    if ratio
      t("reports.transactions_breakdown.vs_normal.#{direction}_#{timing}_html", amount: amount, percent: number_to_percentage(ratio.abs * 100, precision: 0))
    else
      t("reports.transactions_breakdown.vs_normal.#{direction}_#{timing}_no_percent_html", amount: amount)
    end
  end

  # The key under an expense list: what the tick marks, and which days normal comes from
  def breakdown_normal_key(comparison)
    t(comparison.in_progress? ? "reports.transactions_breakdown.vs_normal.key_so_far" : "reports.transactions_breakdown.vs_normal.key_period",
      normal: breakdown_money(comparison.normal_total),
      range: t("reports.index.period_nav.range",
               start: l(comparison.baseline_period.start_date, format: "%b %-d, %Y"),
               end: l(comparison.baseline_period.end_date, format: "%b %-d, %Y")))
  end

  def breakdown_money(amount, precision: 0)
    Money.new(amount, Current.family.currency).format(precision: precision)
  end

  private
    def breakdown_key(category)
      IncomeStatement::CategoryNetting.key(category)
    end

    def breakdown_row(group, total:, days:, start_date:, end_date:, comparison:, compared:)
      subs_by_key = (compared&.subcategories || []).index_by do |sub|
        sub.direct ? "#{group[:category_id]}_other" : breakdown_key(sub.category)
      end

      row = breakdown_item(group, total: total, start_date: start_date, end_date: end_date, comparison: comparison, compared: compared)
      row[:subcategories] = Array(group[:subcategories]).map do |sub|
        breakdown_item(sub, total: total, start_date: start_date, end_date: end_date, comparison: comparison, compared: subs_by_key[sub[:category_id].to_s])
      end
      row[:details] = breakdown_details(group, days: days, compared: compared)
      row
    end

    def breakdown_item(item, total:, start_date:, end_date:, comparison:, compared:)
      {
        key: item[:category_id].to_s,
        name: item[:category_name],
        color: item[:category_color] || Category::UNCATEGORIZED_COLOR,
        icon: item[:category_icon],
        amount: item[:total],
        share: total.positive? ? (item[:total] / total.to_f * 100).round(1) : 0,
        href: breakdown_href(item, start_date, end_date),
        normal: compared&.normal,
        change: compared&.change,
        delta: compared && breakdown_change_delta(comparison, compared)
      }
    end

    # A comparison row with no spending this period, as a list row at zero
    def breakdown_missing_row(compared, comparison:)
      category = compared.category
      {
        key: breakdown_key(category),
        name: category.name,
        color: category.color || Category::UNCATEGORIZED_COLOR,
        icon: category.lucide_icon,
        amount: 0,
        share: 0,
        href: nil,
        normal: compared.normal,
        change: compared.change,
        delta: breakdown_change_delta(comparison, compared),
        subcategories: [],
        details: [ t("reports.transactions_breakdown.details.nothing_spent"), t("reports.transactions_breakdown.details.normal", amount: breakdown_money(compared.normal)) ]
      }
    end

    def breakdown_place_on_scale(row, scale)
      row[:bar] = scale.positive? ? (row[:amount] / scale * 100).to_f.round(2) : 0
      row[:tick] = scale.positive? && row[:normal] ? [ (row[:normal] / scale * 100).to_f.round(2), 100 ].min : nil
    end

    # The detail lines a row opens to: transactions, average, per day and normal
    def breakdown_details(group, days:, compared:)
      count = group[:count]
      facts = [ t("reports.transactions_breakdown.column.transactions", count: count) ]
      facts << t("reports.transactions_breakdown.details.average", amount: breakdown_money(group[:total] / count)) if count > 1
      facts << t("reports.transactions_breakdown.details.per_day", amount: breakdown_money(group[:total] / days)) if days&.positive?

      facts << t("reports.transactions_breakdown.details.netted_#{group[:type]}", amount: breakdown_money(group[:netted])) if group[:netted].to_d.positive?

      lines = [ facts.join(", ") ]
      lines << t("reports.transactions_breakdown.details.normal", amount: breakdown_money(compared.normal)) if compared&.normal
      lines
    end

    def breakdown_change_delta(comparison, compared)
      return nil unless compared.change && compared.change.abs >= IncomeStatement::SpendingComparison::MIN_CHANGE

      breakdown_delta(compared.change, tone: spending_ratio_bucket(comparison, compared)&.dig(:tone) || :neutral)
    end

    def breakdown_delta(change, tone:)
      return nil if change.abs < IncomeStatement::SpendingComparison::MIN_CHANGE

      {
        label: "#{change.negative? ? "−" : "+"}#{breakdown_money(change.abs)}",
        tone_class: BREAKDOWN_TONE_CLASSES.fetch(tone),
        direction: change.negative? ? "less" : "more"
      }
    end

    # /transactions lists only transactions, so a row that holds only trades (Other
    # Investments) gets no link. A row with no exact filter (the synthetic Other row)
    # has no filter_value and gets no link either.
    def breakdown_href(item, start_date, end_date)
      return nil unless item[:has_transactions] && item[:filter_value].present? && start_date && end_date

      transactions_path(q: { categories: [ item[:filter_value] ], start_date: start_date, end_date: end_date })
    end
end
