require "digest/md5"

class IncomeStatement
  include Monetizable

  monetize :median_expense, :median_income

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def totals(transactions_scope: nil, date_range:)
    # Default to excluding pending transactions from budget/analytics calculations
    # Pending transactions shouldn't affect budget totals until they post
    transactions_scope ||= family.transactions.visible.excluding_pending

    result = totals_query(transactions_scope: transactions_scope, date_range: date_range)

    total_income = result.select { |t| t.classification == "income" }.sum(&:total)
    total_expense = result.select { |t| t.classification == "expense" }.sum(&:total)

    ScopeTotals.new(
      transactions_count: result.sum(&:transactions_count),
      income_money: Money.new(total_income, family.currency),
      expense_money: Money.new(total_expense, family.currency)
    )
  end

  # Memoized per instance and period: a page that shows several figures of one period
  # (the dashboard, a budget, the reports) builds each total once.
  def expense_totals(period: Period.current_month)
    period_total(classification: "expense", period: period)
  end

  def income_totals(period: Period.current_month)
    period_total(classification: "income", period: period)
  end

  # Investment contributions count as spending (decision 29), so nothing leaves Cash
  # Flow as a separate Invested outflow. Kept so the Sankey reads one interface if a
  # family setting for this ever comes back.
  def invested_total(period: Period.current_month)
    Money.new(0, family.currency)
  end

  # Per-day net spending of a period ({ date => amount }), for the dashboard's
  # cumulative spending curve (IncomeStatement::SpendingTrend). Refunds net within their
  # category on the day they land. A category whose period net is not spending (income,
  # or refunded more than spent) stays out, as in IncomeStatement::CategoryNetting, so
  # the last cumulative point equals the Sankey's spending.
  #
  # category_ids narrows it to those categories: ids, plus
  # Category::UNCATEGORIZED_FILTER_VALUE for uncategorized spending. A parent covers its
  # subcategories, as in the transactions category filter. nil means every category.
  def daily_expense_series(period:, category_ids: nil)
    rows = daily_spending_rows(period)
    if category_ids
      matches = expense_category_matcher(category_ids)
      rows = rows.select { |row| matches.call(row.category_id) }
    end

    rows.group_by(&:date).transform_values { |day_rows| day_rows.sum(&:amount) }
  end

  # Categories with spending in the period's daily series, nil standing for
  # uncategorized spending: the categories a filter on that series can offer.
  def daily_expense_category_ids(period:)
    daily_spending_rows(period).map(&:category_id).uniq
  end

  def median_expense(interval: "month", category: nil, exclude_current_period: false)
    if category.present?
      category_stats(interval: interval, exclude_current_period: exclude_current_period)
        .find { |stat| stat.classification == "expense" && stat.category_id == category.id }&.median || 0
    else
      family_stats(interval: interval, exclude_current_period: exclude_current_period)
        .find { |stat| stat.classification == "expense" }&.median || 0
    end
  end

  def avg_expense(interval: "month", category: nil, exclude_current_period: false)
    if category.present?
      category_stats(interval: interval, exclude_current_period: exclude_current_period)
        .find { |stat| stat.classification == "expense" && stat.category_id == category.id }&.avg || 0
    else
      family_stats(interval: interval, exclude_current_period: exclude_current_period)
        .find { |stat| stat.classification == "expense" }&.avg || 0
    end
  end

  def median_income(interval: "month", exclude_current_period: false)
    family_stats(interval: interval, exclude_current_period: exclude_current_period)
      .find { |stat| stat.classification == "income" }&.median || 0
  end

  private
    ScopeTotals = Data.define(:transactions_count, :income_money, :expense_money)
    PeriodTotal = Data.define(:classification, :total, :currency, :category_totals)
    CategoryTotal = Data.define(:category, :total, :currency, :weight)

    # Every category of the family, loaded once, with the parent that views and
    # callers read from a subcategory.
    def categories
      @categories ||= family.categories.includes(:parent).to_a
    end

    def period_memo_key(period)
      [ period.start_date, period.end_date ]
    end

    def period_total(classification:, period:)
      @period_totals ||= {}
      @period_totals[[ classification, *period_memo_key(period) ]] ||= build_period_total(classification: classification, period: period)
    end

    # One totals query per period serves both classifications.
    def totals_for_period(period)
      @totals_for_period ||= {}
      # Exclude pending transactions from budget calculations
      @totals_for_period[period_memo_key(period)] ||= totals_query(
        transactions_scope: family.transactions.visible.excluding_pending.in_period(period),
        date_range: period.date_range
      )
    end

    def build_period_total(classification:, period:)
      totals = totals_for_period(period).select { |t| t.classification == classification }
      classification_total = totals.sum(&:total)

      # Indexed once, so each category reads its rows without scanning every row.
      # The nil category_id holds both uncategorized rows and uncategorized investments.
      totals_by_category_id = totals.group_by(&:category_id)
      totals_by_parent_id = totals.select(&:parent_category_id).group_by(&:parent_category_id)
      uncategorized_rows = totals_by_category_id.fetch(nil, [])

      uncategorized_category = family.categories.uncategorized
      other_investments_category = family.categories.other_investments

      category_totals = [ *categories, uncategorized_category, other_investments_category ].map do |category|
        parent_category_total = if category.uncategorized?
          # Regular uncategorized: NULL category_id and NOT uncategorized investment
          uncategorized_rows.reject(&:is_uncategorized_investment).sum(&:total)
        elsif category.other_investments?
          # Other investments: NULL category_id AND is_uncategorized_investment
          uncategorized_rows.select(&:is_uncategorized_investment).sum(&:total)
        else
          totals_by_category_id.fetch(category.id, []).sum(&:total)
        end

        children_totals = category.synthetic? ? 0 : totals_by_parent_id.fetch(category.id, []).sum(&:total)

        category_total = parent_category_total + children_totals

        weight = (category_total.zero? ? 0 : category_total.to_f / classification_total) * 100

        CategoryTotal.new(
          category: category,
          total: category_total,
          currency: family.currency,
          weight: weight,
        )
      end

      PeriodTotal.new(
        classification: classification,
        total: category_totals.reject { |ct| ct.category.subcategory? }.sum(&:total),
        currency: family.currency,
        category_totals: category_totals.freeze
      )
    end

    # The period's daily rows of the categories that net to spending. Memoized per
    # period: the curve and its category filter read the same rows.
    def daily_spending_rows(period)
      @daily_spending_rows ||= {}
      @daily_spending_rows[period_memo_key(period)] ||= begin
        rows = daily_expense_rows(period)
        spending_ids = rows.group_by(&:category_id).select { |_id, category_rows| category_rows.sum(&:amount).positive? }.keys
        rows.select { |row| spending_ids.include?(row.category_id) }
      end
    end

    # Cached per period and never per category filter: every selection reads these rows.
    # They carry only the category id, so moving a subcategory under another parent
    # takes effect without a new key.
    def daily_expense_rows(period)
      Rails.cache.fetch([
        "income_statement", "daily_expense_rows", "v1", family.id, period.start_date.iso8601, period.end_date.iso8601,
        family.entries_cache_version, ExchangeRate.conversion_cache_key(family.currency)
      ], expires_in: Family::AGGREGATE_CACHE_TTL) do
        DailyExpenseTotals.new(
          family,
          transactions_scope: family.transactions.visible.excluding_pending.in_period(period),
          date_range: period.date_range
        ).call
      end
    end

    # A predicate over a row's category_id for a selection, expanding each selected
    # parent to its current subcategories (categories nest one level deep). Memoized per
    # selection, since one request filters two periods the same way.
    def expense_category_matcher(category_ids)
      key = category_ids.map(&:to_s).sort
      (@expense_category_matchers ||= {})[key] ||= begin
        selected = key.to_set
        selected.merge(categories.filter_map { |category| category.id.to_s if selected.include?(category.parent_id.to_s) })

        ->(category_id) { selected.include?(category_id.nil? ? Category::UNCATEGORIZED_FILTER_VALUE : category_id.to_s) }
      end
    end

    # The stats depend on today's period (which one is current, and where the category
    # average window ends), so a new period means a new cache key. today is the family's
    # date: requests and jobs run in its time zone.
    def family_stats(interval: "month", exclude_current_period: false)
      @family_stats ||= {}
      today = Date.current
      fiscal_key = [ family.use_fiscal_months, family.fiscal_start_day ]
      period_key = current_period_start(interval, today).iso8601
      cache_key = [ interval, fiscal_key, exclude_current_period, period_key ]
      @family_stats[cache_key] ||= Rails.cache.fetch([
        "income_statement", "family_stats", "v2", family.id, interval, fiscal_key, exclude_current_period, period_key, family.entries_cache_version,
        ExchangeRate.conversion_cache_key(family.currency)
       ], expires_in: Family::AGGREGATE_CACHE_TTL) { FamilyStats.new(family, interval:, exclude_current_period:, today:).call }
    end

    def category_stats(interval: "month", exclude_current_period: false)
      @category_stats ||= {}
      today = Date.current
      fiscal_key = [ family.use_fiscal_months, family.fiscal_start_day ]
      period_key = current_period_start(interval, today).iso8601
      cache_key = [ interval, fiscal_key, exclude_current_period, period_key ]
      @category_stats[cache_key] ||= Rails.cache.fetch([
        "income_statement", "category_stats", "v3", family.id, interval, fiscal_key, exclude_current_period, period_key, family.entries_cache_version,
        ExchangeRate.conversion_cache_key(family.currency)
       ], expires_in: Family::AGGREGATE_CACHE_TTL) { CategoryStats.new(family, interval:, exclude_current_period:, today:).call }
    end

    # Start of the stats period that contains today, matching the SQL: date_trunc of the
    # date shifted back by the fiscal offset (Postgres weeks start on Monday)
    def current_period_start(interval, today)
      offset_days = family.fiscal_month_enabled? ? family.fiscal_start_day.to_i - 1 : 0
      shifted = today - offset_days

      case interval.to_s
      when "day" then shifted
      when "week" then shifted.beginning_of_week(:monday)
      when "quarter" then shifted.beginning_of_quarter
      when "year" then shifted.beginning_of_year
      else shifted.beginning_of_month
      end
    end

    def totals_query(transactions_scope:, date_range:)
      sql_hash = Digest::MD5.hexdigest(transactions_scope.to_sql)

      Rails.cache.fetch([
        "income_statement", "totals_query", "v2", family.id, sql_hash, family.entries_cache_version,
        ExchangeRate.conversion_cache_key(family.currency)
       ], expires_in: Family::AGGREGATE_CACHE_TTL) { Totals.new(family, transactions_scope: transactions_scope, date_range: date_range).call }
    end

    def monetizable_currency
      family.currency
    end
end
