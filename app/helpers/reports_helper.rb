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

  # --- Spending vs normal (the expenses block of the activity breakdown) ---

  # Treemap colours by change against normal, smallest first. upper is the largest
  # ratio (0.5 = 50% more) that still falls in the bucket; nil means no limit.
  SPENDING_RATIO_BUCKETS = [
    { key: "less", upper: -0.5, color: "var(--color-success)" },
    { key: "slightly_less", upper: -0.15, color: "color-mix(in oklab, var(--color-success) 55%, var(--color-gray-400))" },
    { key: "normal", upper: 0.15, color: "var(--color-gray-400)" },
    { key: "slightly_more", upper: 0.5, color: "color-mix(in oklab, var(--color-destructive) 45%, var(--color-gray-400))" },
    { key: "more", upper: 1.0, color: "color-mix(in oklab, var(--color-destructive) 75%, var(--color-gray-400))" },
    { key: "much_more", upper: nil, color: "var(--color-destructive)" }
  ].freeze
  SPENDING_NO_NORMAL_COLOR = "var(--color-gray-400)".freeze
  # A breakdown tile whose category has no colour
  BREAKDOWN_FALLBACK_COLOR = "#94a3b8".freeze

  # The bucket of a comparison row, or nil without a normal. Spending where normal is
  # zero is new spending, so it counts as much more.
  def spending_ratio_bucket(comparison, row)
    return nil unless comparison.comparable? && row.normal

    ratio = row.ratio
    return SPENDING_RATIO_BUCKETS.last if ratio.nil? && row.total.positive?
    return SPENDING_RATIO_BUCKETS.find { |bucket| bucket[:key] == "normal" } if ratio.nil?

    SPENDING_RATIO_BUCKETS.find { |bucket| bucket[:upper].nil? || ratio <= bucket[:upper] }
  end

  # Nodes for the reports-treemap controller from the groups of one breakdown table
  # (income or expenses). With a comparable spending comparison, each node also gets its
  # colour and tooltip lines against normal, matched by category, so one treemap can
  # switch between category colours and the change against normal.
  def breakdown_treemap_categories(groups, total:, start_date:, end_date:, comparison: nil)
    currency = Current.family.currency
    days_in_period = start_date && end_date ? (end_date - start_date).to_i + 1 : 30
    comparison = nil unless comparison&.comparable?
    rows_by_key = comparison ? comparison.rows.index_by { |row| IncomeStatement::CategoryNetting.key(row.category) } : {}

    groups.each_with_index.map do |group, index|
      node = {
        name: group[:category_name],
        color: group[:category_color] || BREAKDOWN_FALLBACK_COLOR,
        percentage: (group[:total] / total.to_f * 100).round(1),
        amount: group[:total],
        formattedAmount: Money.new(group[:total], currency).format,
        count: group[:count],
        avgFormatted: group[:count] > 1 ? Money.new(group[:total] / group[:count], currency).format : nil,
        dailyAvgFormatted: days_in_period > 0 ? Money.new(group[:total] / days_in_period, currency).format : nil,
        rank: index + 1,
        subcategories: (group[:subcategories] || []).first(3).map do |sub|
          {
            name: sub[:category_name],
            color: sub[:category_color] || group[:category_color] || BREAKDOWN_FALLBACK_COLOR,
            amount: Money.new(sub[:total], currency).format,
            percentage: group[:total] > 0 ? (sub[:total] / group[:total].to_f * 100).round(1) : 0
          }
        end,
        totalSubcategories: (group[:subcategories] || []).size,
        href: breakdown_category_href(group, start_date, end_date)
      }

      if comparison
        # Category#totals_key: an id, or uncategorized / other_investments
        row = rows_by_key[group[:category_id].to_s]
        node[:normalColor] = (row && spending_ratio_bucket(comparison, row)&.dig(:color)) || SPENDING_NO_NORMAL_COLOR
        node[:normalLines] = row ? spending_normal_lines(comparison, row) : [ t("reports.spending_vs_normal.tooltip.no_normal") ]
      end

      node
    end
  end

  # The change list: rows that moved against normal, with the bar width as a share of
  # the largest change
  def spending_changes(comparison)
    changes = comparison.changes
    max_change = changes.map { |row| row.change.abs }.max

    changes.map do |row|
      {
        row: row,
        width: (row.change.abs / max_change * 100).to_f.round(1),
        amount_label: "#{row.change.negative? ? "−" : "+"}#{spending_money(row.change.abs, precision: 0)}",
        href: spending_category_href(comparison, row.category)
      }
    end
  end

  def spending_money(amount, precision: 2)
    Money.new(amount, Current.family.currency).format(precision: precision)
  end

  private
    def spending_normal_lines(comparison, row)
      return [ t("reports.spending_vs_normal.tooltip.no_normal") ] unless comparison.comparable? && row.normal

      lines = [ t("reports.spending_vs_normal.tooltip.normal", amount: spending_money(row.normal)) ]
      if row.change.abs >= IncomeStatement::SpendingComparison::MIN_CHANGE
        direction = row.change.negative? ? "less" : "more"
        amount = spending_money(row.change.abs)
        lines << if row.ratio
          t("reports.spending_vs_normal.tooltip.#{direction}", amount: amount, percent: number_to_percentage(row.ratio.abs * 100, precision: 0))
        else
          t("reports.spending_vs_normal.tooltip.#{direction}_no_percent", amount: amount)
        end
      end
      lines
    end

    def breakdown_category_href(group, start_date, end_date)
      return nil unless group[:has_transactions] && group[:filter_value].present? && start_date && end_date

      transactions_path(q: { categories: [ group[:filter_value] ], start_date: start_date, end_date: end_date })
    end

    # Other Investments has no transactions filter, so it gets no link
    def spending_category_href(comparison, category)
      return nil if category.other_investments?

      transactions_path(q: {
        categories: [ category.filter_value ],
        start_date: comparison.period.start_date,
        end_date: comparison.period.end_date
      })
    end
end
