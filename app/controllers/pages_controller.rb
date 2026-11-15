class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.family.accounts.visible.with_attached_logo

    period_param = params[:cashflow_period]
    @cashflow_period = if period_param.present?
      if period_param == "custom"
        # Allow users to specify an explicit date range for the cashflow chart
        last_30 = Period.last_30_days
        start_date = safe_parse_date(params[:cashflow_start_date]) || last_30.start_date
        end_date   = safe_parse_date(params[:cashflow_end_date])   || last_30.end_date

        # Ensure start_date <= end_date
        if start_date > end_date
          start_date, end_date = end_date, start_date
        end

        Period.custom(start_date: start_date, end_date: end_date)
      else
        begin
          Period.from_key(period_param)
        rescue Period::InvalidKeyError
          # Fall back to the same period used elsewhere (user preference via Periodable)
          @period
        end
      end
    else
      # Default to the globally selected period (from Periodable),
      # which uses the current user's default when not provided via params
      @period
    end

    # Parse net_worth_period (independent period for net worth chart)
    net_worth_period_param = params[:net_worth_period]
    @net_worth_period = if net_worth_period_param.present?
      if net_worth_period_param == "custom"
        last_30 = Period.last_30_days
        start_date = safe_parse_date(params[:net_worth_start_date]) || last_30.start_date
        end_date   = safe_parse_date(params[:net_worth_end_date])   || last_30.end_date
        start_date, end_date = end_date, start_date if start_date > end_date
        Period.custom(start_date: start_date, end_date: end_date)
      else
        begin
          Period.from_key(net_worth_period_param)
        rescue Period::InvalidKeyError
          @period
        end
      end
    else
      @period
    end

    # Parse outflows_period (independent period for outflows chart)
    outflows_period_param = params[:outflows_period]
    @outflows_period = if outflows_period_param.present?
      if outflows_period_param == "custom"
        last_30 = Period.last_30_days
        start_date = safe_parse_date(params[:outflows_start_date]) || last_30.start_date
        end_date   = safe_parse_date(params[:outflows_end_date])   || last_30.end_date
        start_date, end_date = end_date, start_date if start_date > end_date
        Period.custom(start_date: start_date, end_date: end_date)
      else
        begin
          Period.from_key(outflows_period_param)
        rescue Period::InvalidKeyError
          @period
        end
      end
    else
      @period
    end

    # Parse investment_period (independent period for investment summary)
    investment_period_param = params[:investment_period]
    @investment_period = if investment_period_param.present?
      if investment_period_param == "custom"
        last_30 = Period.last_30_days
        start_date = safe_parse_date(params[:investment_start_date]) || last_30.start_date
        end_date   = safe_parse_date(params[:investment_end_date])   || last_30.end_date
        start_date, end_date = end_date, start_date if start_date > end_date
        Period.custom(start_date: start_date, end_date: end_date)
      else
        begin
          Period.from_key(investment_period_param)
        rescue Period::InvalidKeyError
          @period
        end
      end
    else
      @period
    end

    # Toggle: show/hide subcategories in Sankey (default: false)
    @cashflow_show_subcategories = if params.key?(:cashflow_show_subcategories)
      ActiveModel::Type::Boolean.new.cast(params[:cashflow_show_subcategories])
    else
      false
    end

    # One payload with subcategories; the chart drops the subcategory column itself
    # when the toggle is off, so the toggle needs no request
    @cashflow_sankey_data = IncomeStatement::Sankey.new(Current.family.income_statement, period: @cashflow_period).as_json

    # Outflows uses its own period
    outflows_expense_totals = Current.family.income_statement.expense_totals(period: @outflows_period)
    @outflows_data = build_outflows_donut_data(outflows_expense_totals)

    # Load subscriptions for the summary widget
    @upcoming_subscriptions = Current.family.recurring_transactions
                                    .active_subscriptions
                                    .where("next_expected_date <= ?", 7.days.from_now.to_date)
                                    .where("next_expected_date >= ?", Date.current)
                                    .order(:next_expected_date)
                                    .limit(5)
                                    .includes(:merchant, :subscription_service)
                                    .with_attached_logo

    @subscriptions_monthly_total = calculate_subscriptions_monthly_total
    @subscription_suggestion_count = Current.family.recurring_transactions.suggested.count
    @subscriptions_due_today = Current.family.recurring_transactions
                                      .active_subscriptions
                                      .where(next_expected_date: Date.current)
                                      .count
    @subscriptions_this_week_total = calculate_this_week_subscriptions_total

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
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
      params.expect(preferences: [ collapsed_sections: {}, section_order: [] ]).to_h
    end

    def build_dashboard_sections
      all_sections = [
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          locals: { sankey_data: @cashflow_sankey_data, period: @cashflow_period, show_subcategories: @cashflow_show_subcategories },
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          locals: { outflows_data: @outflows_data, period: @outflows_period },
          visible: Current.family.accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          locals: { investment_statement: @investment_statement, period: @investment_period },
          visible: Current.family.accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          locals: { balance_sheet: @balance_sheet, period: @net_worth_period },
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          locals: { balance_sheet: @balance_sheet },
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "subscriptions_summary",
          title: "pages.dashboard.subscriptions_summary.title",
          partial: "pages/dashboard/subscriptions_summary",
          locals: {
            upcoming_subscriptions: @upcoming_subscriptions,
            monthly_total: @subscriptions_monthly_total,
            suggestion_count: @subscription_suggestion_count,
            due_today_count: @subscriptions_due_today,
            this_week_total: @subscriptions_this_week_total
          },
          visible: Current.family.recurring_transactions.subscriptions.any?,
          collapsible: true
        }
      ]

      # Order sections according to user preference
      section_order = Current.user.dashboard_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing)
      all_sections.each do |section|
        ordered_sections << section unless ordered_sections.include?(section)
      end

      ordered_sections
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

    def safe_parse_date(value)
      return nil if value.blank?
      Date.parse(value)
    rescue ArgumentError
      nil
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
