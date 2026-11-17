class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  # The dashboard widgets, in their default order when the saved order leaves one out
  DASHBOARD_SECTION_KEYS = %w[
    cashflow_sankey outflows_donut spending_trend investment_summary net_worth_chart balance_sheet subscriptions_summary
    insights_feed
  ].freeze

  # The period widgets share one period (period, start_date, end_date), as upstream's do.
  # A change in any of them reloads each of their frames (dashboard_period_controller.js),
  # and a frame request builds only that frame's widget.
  DASHBOARD_PERIOD_FRAMES = %w[cashflow_sankey_section outflows_donut_section investment_summary_section net_worth_section].freeze

  # A frame request builds only the widget that frame holds
  DASHBOARD_FRAME_SECTIONS = {
    "cashflow_sankey_section" => "cashflow_sankey",
    "outflows_donut_section" => "outflows_donut",
    "spending_trend_section" => "spending_trend",
    "spending_trend_fullscreen_section" => "spending_trend",
    "investment_summary_section" => "investment_summary",
    "net_worth_section" => "net_worth_chart"
  }.freeze

  # Query params that shape what the dashboard shows without being saved. Customize mode
  # carries them through its links and buttons, so the widgets keep their periods.
  DASHBOARD_VIEW_PARAMS = %i[period start_date end_date cashflow_show_subcategories spending_period].freeze

  # The view params that hold a list (the spending curve's category filter)
  DASHBOARD_VIEW_ARRAY_PARAMS = %i[spending_category_ids].freeze

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.family.accounts.visible.with_attached_logo
    @has_accounts = Current.family.accounts.any?

    # Toggle: show/hide subcategories in Sankey (default: false)
    @cashflow_show_subcategories = if params.key?(:cashflow_show_subcategories)
      ActiveModel::Type::Boolean.new.cast(params[:cashflow_show_subcategories])
    else
      false
    end

    @dashboard_sections, @hidden_dashboard_sections = build_dashboard_sections
    @customizing_dashboard = params[:customize].present?
    @dashboard_view_params = dashboard_view_params
    @just_hidden_section = params[:hidden_section]
    @just_shown_section = params[:shown_section]

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("pages.dashboard.breadcrumb"), nil ] ]
  end

  # Saves collapsed, hidden and order preferences. The sortable and collapse controllers
  # send JSON and get 200. The Customize mode's hide and show buttons are forms with
  # customize set, and go back to the dashboard.
  def update_preferences
    prefs = dashboard_preferences_params
    saved = Current.user.update_dashboard_preferences(prefs, laid_out_order: ordered_dashboard_section_keys)

    if params[:customize].present?
      redirect_to root_path(dashboard_view_params.merge(customize: 1, **changed_section_param(prefs))), status: :see_other
    elsif saved
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def redis_configuration_error
    render layout: "blank"
  end

  private
    def preferences_params
      params.expect(preferences: [ collapsed_sections: {}, hidden_sections: {}, section_order: [] ]).to_h
    end

    # Hidden flags are stored as booleans and only for widgets that exist
    def dashboard_preferences_params
      prefs = preferences_params
      if prefs.key?("hidden_sections")
        prefs["hidden_sections"] = prefs["hidden_sections"].to_h
          .slice(*DASHBOARD_SECTION_KEYS)
          .transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) == true }
      end
      prefs
    end

    # Two param names, so hiding a widget and showing it again never redirect to the same
    # URL: Turbo morphs a same-URL visit as a refresh, and a morph skips the autofocus
    # that keeps keyboard users on the widget they changed.
    def changed_section_param(prefs)
      key, hidden = prefs["hidden_sections"]&.first
      return {} unless key

      hidden ? { hidden_section: key } : { shown_section: key }
    end

    def dashboard_view_params
      params.slice(*DASHBOARD_VIEW_PARAMS, *DASHBOARD_VIEW_ARRAY_PARAMS)
        .permit(*DASHBOARD_VIEW_PARAMS, DASHBOARD_VIEW_ARRAY_PARAMS.index_with { [] })
        .to_h.symbolize_keys
    end

    # Each widget builds its own data, so a hidden widget's builder is never called and
    # its queries never run
    def dashboard_section_builders
      {
        "cashflow_sankey" => -> {
          # One payload with subcategories; the chart drops the subcategory column itself
          # when the toggle is off, so the toggle needs no request
          sankey_data = IncomeStatement::Sankey.new(Current.family.income_statement, period: @period).as_json
          {
            key: "cashflow_sankey",
            title: "pages.dashboard.cashflow_sankey.title",
            partial: "pages/dashboard/cashflow_sankey",
            locals: { sankey_data: sankey_data, period: @period, show_subcategories: @cashflow_show_subcategories },
            # Outside the section, so it stays open while the section's frame reloads
            dialog: {
              partial: "pages/dashboard/cashflow_sankey_dialog",
              locals: { sankey_data: sankey_data, period: @period, show_subcategories: @cashflow_show_subcategories }
            },
            visible: @has_accounts,
            collapsible: true
          }
        },
        "outflows_donut" => -> {
          outflows_data = build_outflows_donut_data(Current.family.income_statement.expense_totals(period: @period))
          {
            key: "outflows_donut",
            title: "pages.dashboard.outflows_donut.title",
            partial: "pages/dashboard/outflows_donut",
            locals: { outflows_data: outflows_data, period: @period },
            # Shown with an empty state when the period has no outflows: another
            # widget's period change reloads its frame, which must then be there
            visible: @has_accounts,
            collapsible: true
          }
        },
        "spending_trend" => -> {
          spending_trend_data = build_spending_trend_data
          {
            key: "spending_trend",
            title: "pages.dashboard.spending_trend.title",
            partial: "pages/dashboard/spending_trend",
            locals: { spending_trend_data: spending_trend_data },
            # Outside the section, so it stays open while the section's frame reloads
            dialog: {
              partial: "pages/dashboard/spending_trend_dialog",
              locals: { spending_trend_data: spending_trend_data }
            },
            visible: @has_accounts,
            collapsible: true
          }
        },
        "investment_summary" => -> {
          {
            key: "investment_summary",
            title: "pages.dashboard.investment_summary.title",
            partial: "pages/dashboard/investment_summary",
            locals: { investment_statement: @investment_statement, period: @period },
            visible: investment_summary_available?,
            collapsible: true
          }
        },
        "net_worth_chart" => -> {
          {
            key: "net_worth_chart",
            title: "pages.dashboard.net_worth_chart.title",
            partial: "pages/dashboard/net_worth_chart",
            locals: { balance_sheet: @balance_sheet, period: @period },
            dialog: {
              partial: "pages/dashboard/net_worth_chart_dialog",
              locals: { balance_sheet: @balance_sheet, period: @period }
            },
            visible: @has_accounts,
            collapsible: true
          }
        },
        "balance_sheet" => -> {
          {
            key: "balance_sheet",
            title: "pages.dashboard.balance_sheet.title",
            partial: "pages/dashboard/balance_sheet",
            locals: { balance_sheet: @balance_sheet },
            visible: @has_accounts,
            collapsible: true
          }
        },
        "subscriptions_summary" => -> {
          {
            key: "subscriptions_summary",
            title: "pages.dashboard.subscriptions_summary.title",
            partial: "pages/dashboard/subscriptions_summary",
            locals: subscriptions_summary_locals,
            visible: subscriptions_summary_available?,
            collapsible: true
          }
        },
        # Insights feed (w3-reports): shown while there is an insight to read
        "insights_feed" => -> {
          insights = Current.family.insights.visible.ordered.to_a
          {
            key: "insights_feed",
            title: "pages.dashboard.insights_feed.title",
            partial: "pages/dashboard/insights_feed",
            locals: { insights: insights.first(Insight::FEED_LIMIT), total_count: insights.size },
            visible: @has_accounts && insights.any?,
            collapsible: true
          }
        }
      }
    end

    # Returns [shown, hidden]. A widget with nothing to show is dropped from both, so the
    # hidden list never offers back a widget that would not appear.
    def build_dashboard_sections
      builders = dashboard_section_builders
      keys = ordered_dashboard_section_keys
      frame_key = DASHBOARD_FRAME_SECTIONS[request.headers["Turbo-Frame"]]
      keys &= [ frame_key ] if frame_key

      sections = keys.filter_map do |key|
        Current.user.dashboard_section_hidden?(key) ? hidden_dashboard_section(key) : builders.fetch(key).call
      end

      hidden, shown = sections.select { |section| section[:visible] }.partition { |section| section[:hidden] }
      [ shown, hidden ]
    end

    # Just enough for the hidden list, without the widget's queries. A widget whose data
    # depends on the period stays on offer, since another period may have data.
    def hidden_dashboard_section(key)
      visible = case key
      when "investment_summary" then investment_summary_available?
      when "subscriptions_summary" then subscriptions_summary_available?
      else @has_accounts
      end

      { key: key, title: "pages.dashboard.#{key}.title", visible: visible, hidden: true }
    end

    # The order the dashboard lays its widgets out in: the saved order, then any widget
    # it leaves out
    def ordered_dashboard_section_keys
      saved = Current.user.dashboard_section_order & DASHBOARD_SECTION_KEYS
      saved + (DASHBOARD_SECTION_KEYS - saved)
    end

    def investment_summary_available?
      @has_accounts && @investment_statement.investment_accounts.any?
    end

    def subscriptions_summary_available?
      Current.family.recurring_transactions.subscriptions.any?
    end

    def subscriptions_summary_locals
      {
        upcoming_subscriptions: Current.family.recurring_transactions
          .active_subscriptions
          .where("next_expected_date <= ?", 7.days.from_now.to_date)
          .where("next_expected_date >= ?", Date.current)
          .order(:next_expected_date)
          .limit(5)
          .includes(:merchant, :subscription_service)
          .with_attached_logo,
        monthly_total: calculate_subscriptions_monthly_total,
        suggestion_count: Current.family.recurring_transactions.suggested.count,
        due_today_count: Current.family.recurring_transactions.active_subscriptions.where(next_expected_date: Date.current).count,
        this_week_total: calculate_this_week_subscriptions_total
      }
    end

    def build_outflows_donut_data(expense_totals)
      currency_symbol = Money::Currency.new(expense_totals.currency).symbol
      total = expense_totals.total

      categories = expense_totals.category_totals
        .reject { |ct| ct.category.parent_id.present? || ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            filter_value: ct.category.filter_value,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: expense_totals.currency, currency_symbol: currency_symbol }
    end

    # The spending curve: the budget period that holds the spending_period date (the
    # current one by default; a future one is the current one) against the period before
    # it, both narrowed to the category filter
    def build_spending_trend_data
      income_statement = Current.family.income_statement
      period_date = safe_parse_date(params[:spending_period]) || Date.current
      periods = IncomeStatement::SpendingTrend.periods(Current.family, period_date)

      filter = IncomeStatement::ExpenseCategoryFilter.new(
        income_statement,
        periods: [ periods.current, periods.previous ],
        values: IncomeStatement::ExpenseCategoryFilter.sanitize(Current.family, params[:spending_category_ids])
      )
      trend = IncomeStatement::SpendingTrend.new(income_statement, date: period_date, category_ids: filter.category_ids)

      period_format = t("pages.dashboard.spending_trend.period_format")

      {
        trend: trend,
        filter: filter,
        currency: Current.family.currency,
        current_label: I18n.l(trend.period_start, format: period_format),
        previous_label: I18n.l(trend.previous_period.start_date, format: period_format),
        compact_range: spending_trend_compact_range(trend.current_period),
        period_options: IncomeStatement::SpendingTrend.recent_period_starts(Current.family).map { |start| [ I18n.l(start, format: period_format), start.iso8601 ] },
        chart_data: {
          days: trend.axis_days,
          # Localized here, one per axis day, so the ticks follow the app locale
          axis_labels: trend.axis_dates.map { |date| I18n.l(date, format: :short) },
          current: trend.current_points.map { |point| spending_trend_point_json(point) },
          previous: trend.previous_axis_points.map { |point| spending_trend_point_json(point) }
        }
      }
    end

    def spending_trend_point_json(point)
      { day: point[:day], value: point[:value].to_f.round(2), date_formatted: I18n.l(point[:date], format: :short) }
    end

    # A short range for narrow screens ("Nov 05 - Dec 04, 2026")
    def spending_trend_compact_range(period)
      range = period.date_range
      if range.begin == range.end
        t("pages.dashboard.spending_trend.date_range_short_single", date: I18n.l(range.begin, format: :short), year: range.end.year)
      else
        t("pages.dashboard.spending_trend.date_range_short", start_date: I18n.l(range.begin, format: :short), end_date: I18n.l(range.end, format: :short), year: range.end.year)
      end
    end

    def calculate_subscriptions_monthly_total
      family_currency = Current.family.currency
      Current.family.recurring_transactions.active_subscriptions.sum(Money.new(0, family_currency)) do |sub|
        amount = sub.billing_cycle_yearly? ? sub.amount_money / 12 : sub.amount_money
        subscription_amount_in(amount, family_currency)
      end
    end

    def calculate_this_week_subscriptions_total
      family_currency = Current.family.currency
      Current.family.recurring_transactions
        .active_subscriptions
        .where(next_expected_date: Date.current..Date.current.end_of_week)
        .sum(Money.new(0, family_currency)) do |sub|
          amount = sub.billing_cycle_yearly? ? sub.amount_money / 12 : sub.amount_money
          subscription_amount_in(amount, family_currency)
        end
    end

    # A subscription in a currency with no rate at all is left out of the total (and
    # logged), never counted at 1
    def subscription_amount_in(amount, family_currency)
      ExchangeRate.convert_or_leave_out(amount, to: family_currency, source: "PagesController#subscriptions_total", family: Current.family) ||
        Money.new(0, family_currency)
    end
end
