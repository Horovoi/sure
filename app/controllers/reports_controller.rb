class ReportsController < ApplicationController
  include Periodable

  PERIOD_TYPES = %w[monthly quarterly last_6_months ytd custom].freeze

  # How many months one step of the period arrows moves, per period type.
  # A custom range steps by its own length instead.
  PERIOD_STEP_MONTHS = { monthly: 1, quarterly: 3, last_6_months: 6, ytd: 12 }.freeze

  # The arrows only go back. Fifty years is far more than any history here.
  MIN_PERIOD_OFFSET = -600

  helper_method :report_period_params

  # Allow API key authentication for exports (for Google Sheets integration)
  # Note: We run authentication_for_export which handles both session and API key auth
  skip_authentication only: :export_transactions
  before_action :authenticate_for_export, only: :export_transactions

  # How far apart the period starts of each report period type are, for comparing a
  # period that runs up to today with the same days of earlier periods
  SPENDING_COMPARISON_STEP_MONTHS = { monthly: 1, quarterly: 3, last_6_months: 6, ytd: 12 }.freeze

  def index
    setup_report_data(show_flash: true)

    # Build reports sections for collapsible/reorderable UI
    @reports_sections = build_reports_sections

    @breadcrumbs = [ [ "Home", root_path ], [ "Reports", nil ] ]
  end

  def print
    setup_report_data(show_flash: false)

    render layout: "print"
  end

  def update_preferences
    if Current.user.update_reports_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def export_transactions
    @period_type = parse_period_type
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date

    # Validate and fix date range if end_date is before start_date
    # Don't show flash message since we're returning CSV data
    validate_and_fix_date_range(show_flash: false)

    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    # Build monthly breakdown data for export
    @export_data = build_monthly_breakdown_for_export

    respond_to do |format|
      format.csv do
        csv_data = generate_transactions_csv
        send_data csv_data,
                  filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.csv",
                  type: "text/csv"
      end

      # Excel and PDF exports require additional gems (caxlsx and prawn)
      # Uncomment and install gems if needed:
      #
      # format.xlsx do
      #   xlsx_data = generate_transactions_xlsx
      #   send_data xlsx_data,
      #             filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.xlsx",
      #             type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      # end
      #
      # format.pdf do
      #   pdf_data = generate_transactions_pdf
      #   send_data pdf_data,
      #             filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.pdf",
      #             type: "application/pdf"
      # end
    end
  end

  def google_sheets_instructions
    # Re-build the params needed for the export URL
    base_params = {
      period_type: params[:period_type],
      start_date: params[:start_date],
      end_date: params[:end_date],
      sort_by: params[:sort_by],
      sort_direction: params[:sort_direction]
    }.compact

    # Build the full URL with the API key, if present
    @csv_url = export_transactions_reports_url(base_params.merge(format: :csv))
    @api_key_present = @csv_url.include?("api_key=")

    # This action will render `app/views/reports/google_sheets_instructions.html.erb`
    # It will render *inside* the modal frame.
  end

  private
    def setup_report_data(show_flash: false)
      @period_type = parse_period_type
      @fiscal_mode = params[:fiscal_mode] || default_fiscal_mode
      @period_offset = parse_period_offset
      @start_date = parse_date_param(:start_date) || default_start_date
      @end_date = parse_date_param(:end_date) || default_end_date

      # Validate and fix date range if end_date is before start_date
      validate_and_fix_date_range(show_flash: show_flash)

      # A custom range is the anchor of its arrows: an offset moves it back by
      # whole range lengths.
      @custom_anchor = [ @start_date, @end_date ]
      shift_custom_range if @period_type == :custom

      @period_nav = build_period_nav

      # Build the period
      @period = Period.custom(start_date: @start_date, end_date: @end_date)
      @previous_period = build_previous_period

      # Get aggregated data. One income statement for the whole page: it memoizes each
      # period's totals, so a trend month equal to the selected period is not built again.
      @income_statement = Current.family.income_statement
      @current_income_totals = @income_statement.income_totals(period: @period)
      @current_expense_totals = @income_statement.expense_totals(period: @period)

      @previous_income_totals = @income_statement.income_totals(period: @previous_period)
      @previous_expense_totals = @income_statement.expense_totals(period: @previous_period)

      # Build trend data (last 6 months) — must be before summary metrics (sparklines)
      @trends_data = build_trends_data(income_statement: @income_statement)

      # Calculate summary metrics
      @summary_metrics = build_summary_metrics

      # Net worth metrics
      @net_worth_metrics = build_net_worth_metrics

      # Transactions breakdown
      @transactions = build_transactions_breakdown

      # Investment metrics
      @investment_metrics = build_investment_metrics

      # Investment flows (contributions/withdrawals)
      @investment_flows = InvestmentFlowStatement.new(Current.family).period_totals(period: @period)

      # Flags for view rendering
      @has_accounts = Current.family.accounts.any?
    end

    def preferences_params
      params.expect(preferences: [ reports_collapsed_sections: {}, reports_section_order: [] ]).to_h
    end

    def build_reports_sections
      all_sections = [
        {
          key: "net_worth",
          title: "reports.net_worth.title",
          partial: "reports/net_worth",
          locals: { net_worth_metrics: @net_worth_metrics },
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "trends_insights",
          title: "reports.trends.title",
          partial: "reports/trends_insights",
          locals: { trends_data: @trends_data },
          visible: Current.family.transactions.any?,
          collapsible: true
        },
        {
          key: "investment_performance",
          title: "reports.investment_performance.title",
          partial: "reports/investment_performance",
          locals: { investment_metrics: @investment_metrics },
          visible: @investment_metrics[:has_investments],
          collapsible: true
        },
        {
          key: "investment_flows",
          title: "reports.investment_flows.title",
          partial: "reports/investment_flows",
          locals: { investment_flows: @investment_flows },
          visible: @investment_metrics[:has_investments] && (@investment_flows.contributions.amount > 0 || @investment_flows.withdrawals.amount > 0),
          collapsible: true
        },
        {
          key: "transactions_breakdown",
          title: "reports.transactions_breakdown.title",
          partial: "reports/transactions_breakdown",
          locals: {
            transactions: @transactions,
            period_type: @period_type,
            start_date: @start_date,
            end_date: @end_date
          },
          visible: Current.family.transactions.any?,
          collapsible: true
        },
        spending_vs_normal_section
      ]

      # Order sections according to user preference
      section_order = Current.user.reports_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing)
      all_sections.each do |section|
        ordered_sections << section unless ordered_sections.include?(section)
      end

      ordered_sections
    end

    def spending_vs_normal_section
      {
        key: "spending_vs_normal",
        title: "reports.spending_vs_normal.title",
        partial: "reports/spending_vs_normal",
        locals: { comparison: spending_comparison },
        visible: @has_accounts && Current.family.transactions.any?,
        collapsible: true
      }
    end

    # This period's spending against the year before it, on the page's one income
    # statement
    def spending_comparison
      @spending_comparison ||= IncomeStatement::SpendingComparison.new(
        @income_statement,
        period: @period,
        history_start: IncomeStatement::SpendingComparison.history_start(Current.family),
        step_months: SPENDING_COMPARISON_STEP_MONTHS.fetch(@period_type, 1)
      )
    end

    def validate_and_fix_date_range(show_flash: false)
      return unless @start_date > @end_date

      # Swap the dates to maintain user's intended date range
      @start_date, @end_date = @end_date, @start_date
      flash.now[:alert] = t("reports.invalid_date_range") if show_flash
    end

    def ensure_money(value)
      return value if value.is_a?(Money)
      # Value is numeric (BigDecimal or Integer) in dollars - pass directly to Money.new
      Money.new(value, Current.family.currency)
    end

    def parse_date_param(param_name)
      date_string = params[param_name]
      return nil if date_string.blank?

      Date.parse(date_string)
    rescue Date::Error
      nil
    end

    def parse_period_type
      params[:period_type].to_s.presence_in(PERIOD_TYPES)&.to_sym || :monthly
    end

    # Steps back from the current period: 0 is the current one, -1 the one
    # before. Old links with period_mode=last mean -1. A future period has no
    # data yet, so a positive offset counts as 0.
    def parse_period_offset
      raw = params[:period_offset]
      return -1 if raw.blank? && params[:period_mode] == "last"

      Integer(raw.to_s, 10, exception: false).to_i.clamp(MIN_PERIOD_OFFSET, 0)
    end

    def period_offset
      @period_offset.to_i
    end

    def use_fiscal_periods?
      @fiscal_mode == "true" && Current.family.fiscal_month_enabled?
    end

    def period_step_months
      PERIOD_STEP_MONTHS.fetch(@period_type, 1)
    end

    def default_start_date
      return 1.month.ago.to_date if @period_type == :custom

      shift_period_start(current_period_start, period_offset * period_step_months)
    end

    # The current period runs to today. A past period runs to its last day.
    def default_end_date
      return Date.current if @period_type == :custom || period_offset.zero?

      shift_period_start(default_start_date, period_step_months) - 1.day
    end

    # The start of the period that contains today, fiscal or calendar.
    def current_period_start
      family = Current.family
      today = Date.current
      fiscal = use_fiscal_periods?

      case @period_type
      when :quarterly
        fiscal ? fiscal_quarter_start(today, family) : today.beginning_of_quarter
      when :ytd
        fiscal ? fiscal_year_start(today, family) : today.beginning_of_year
      when :last_6_months
        fiscal ? fiscal_half_year_start(today, family) : beginning_of_half_year(today)
      else
        fiscal ? family.budget_period_start_for(today) : today.beginning_of_month
      end
    end

    # Moves a period start by whole months and keeps it on a period boundary.
    # A fiscal start goes back to the fiscal start day in the new month, so a
    # start clamped in a short month (Feb 28 for day 31) does not stay clamped.
    def shift_period_start(start, months)
      month = start.beginning_of_month >> months
      return month unless use_fiscal_periods?

      Date.new(month.year, month.month, [ Current.family.fiscal_start_day, month.end_of_month.day ].min)
    end

    def shift_custom_range
      return if period_offset.zero?

      length = (@end_date - @start_date).to_i + 1
      @start_date += period_offset * length
      @end_date += period_offset * length
    end

    # The previous and next arrows, the period label, and the link back to
    # the current period. The next arrow is off on the current period.
    def build_period_nav
      at_current = period_offset.zero?

      {
        label: period_label,
        previous_params: period_nav_params(period_offset - 1),
        next_params: at_current ? nil : period_nav_params(period_offset + 1),
        current_params: at_current ? nil : period_nav_params(0)
      }
    end

    def period_nav_params(offset)
      nav_params = if @period_type == :custom
        { period_type: :custom, start_date: @custom_anchor.first, end_date: @custom_anchor.last }
      else
        { period_type: @period_type, fiscal_mode: @fiscal_mode }
      end

      offset.zero? ? nav_params : nav_params.merge(period_offset: offset)
    end

    # The params that show the current report again (print, sort links).
    # Dates win over the offset, so they never move twice; the offset only
    # keeps the arrows in place.
    def report_period_params
      if @period_type == :custom
        { period_type: :custom, start_date: @start_date, end_date: @end_date }
      else
        {
          period_type: @period_type,
          fiscal_mode: @fiscal_mode,
          period_offset: period_offset.nonzero?,
          start_date: @start_date,
          end_date: @end_date
        }.compact
      end
    end

    def period_label
      year = @start_date.year

      case @period_type
      when :monthly
        I18n.l(@start_date, format: "%B %Y")
      when :quarterly
        t("reports.index.period_nav.label.quarterly", quarter: (@start_date.month - 1) / 3 + 1, year: year)
      when :last_6_months
        t("reports.index.period_nav.label.half_year", half: @start_date.month <= 6 ? 1 : 2, year: year)
      when :ytd
        period_offset.zero? ? t("reports.index.period_nav.label.year_to_date", year: year) : year.to_s
      else
        t("reports.index.period_nav.label.custom",
          start: I18n.l(@start_date, format: "%b %-d, %Y"),
          end: I18n.l(@end_date, format: "%b %-d, %Y"))
      end
    end

    def beginning_of_half_year(date)
      date.month <= 6 ? Date.new(date.year, 1, 1) : Date.new(date.year, 7, 1)
    end

    # Fiscal quarter: find the quarter boundary month (Jan/Apr/Jul/Oct) that
    # contains the fiscal month for the given date, then return its fiscal start.
    def fiscal_quarter_start(date, family)
      fiscal_start = family.budget_period_start_for(date)
      quarter_month = ((fiscal_start.month - 1) / 3) * 3 + 1 # 1, 4, 7, or 10
      family.budget_period_start_for(Date.new(fiscal_start.year, quarter_month, family.fiscal_start_day))
    end

    # Fiscal half-year: H1 = Jan–Jun fiscal months, H2 = Jul–Dec fiscal months
    def fiscal_half_year_start(date, family)
      fiscal_start = family.budget_period_start_for(date)
      half_month = fiscal_start.month <= 6 ? 1 : 7
      family.budget_period_start_for(Date.new(fiscal_start.year, half_month, family.fiscal_start_day))
    end

    # Fiscal year: starts at the fiscal month of January
    def fiscal_year_start(date, family)
      fiscal_start = family.budget_period_start_for(date)
      family.budget_period_start_for(Date.new(fiscal_start.year, 1, family.fiscal_start_day))
    end

    def default_fiscal_mode
      Current.family.fiscal_month_enabled? ? "true" : "false"
    end

    def build_previous_period
      duration = (@end_date - @start_date).to_i
      previous_end = @start_date - 1.day
      previous_start = previous_end - duration.days

      Period.custom(start_date: previous_start, end_date: previous_end)
    end

    def build_summary_metrics
      # Ensure we always have Money objects
      current_income = ensure_money(@current_income_totals.total)
      current_expenses = ensure_money(@current_expense_totals.total)
      net_savings = current_income - current_expenses

      previous_income = ensure_money(@previous_income_totals.total)
      previous_expenses = ensure_money(@previous_expense_totals.total)

      # Calculate percentage changes
      income_change = calculate_percentage_change(previous_income, current_income)
      expense_change = calculate_percentage_change(previous_expenses, current_expenses)

      # Get budget performance for current period
      budget_percent = calculate_budget_performance

      # Build trend arrays from @trends_data for sparkline charts
      income_trend = @trends_data.map { |t| t[:income].is_a?(Money) ? t[:income].amount.to_f : t[:income].to_f }
      expense_trend = @trends_data.map { |t| t[:expenses].is_a?(Money) ? t[:expenses].amount.to_f : t[:expenses].to_f }
      net_trend = @trends_data.map { |t| t[:net].is_a?(Money) ? t[:net].amount.to_f : t[:net].to_f }

      {
        current_income: current_income,
        income_change: income_change,
        current_expenses: current_expenses,
        expense_change: expense_change,
        net_savings: net_savings,
        budget_percent: budget_percent,
        income_trend: income_trend,
        expense_trend: expense_trend,
        net_trend: net_trend
      }
    end

    def calculate_percentage_change(previous_value, current_value)
      return 0 if previous_value.zero?

      ((current_value - previous_value) / previous_value * 100).round(1)
    end

    # Share of the current budget spent, as the budget page shows it: the budget for the
    # fiscal period that contains today, spending over the budgeted amount.
    def calculate_budget_performance
      # Only calculate if we're looking at the current month
      return nil unless @period_type == :monthly && (@start_date.to_date..@end_date.to_date).cover?(Date.current)

      budget = Budget.find_for_date(Current.family, Date.current)
      return 0 if budget.nil? || !budget.initialized?

      budget.percent_of_budget_spent.round(1)
    rescue StandardError
      nil
    end

    def build_trends_data(income_statement:)
      # Generate month-by-month data based on the current period filter
      trends = []
      use_fiscal = @fiscal_mode == "true" && Current.family.fiscal_month_enabled?
      family = Current.family

      if use_fiscal
        # Iterate by fiscal month periods
        current_start = family.budget_period_start_for(@start_date)

        while current_start <= @end_date
          fiscal_end = family.budget_period_end_for(current_start)
          month_end = [ fiscal_end, @end_date ].min

          period = Period.custom(start_date: current_start, end_date: month_end)

          income = income_statement.income_totals(period: period).total
          expenses = income_statement.expense_totals(period: period).total

          current_fiscal_start = family.budget_period_start_for(Date.current)

          trends << {
            month: current_start.strftime("%b %Y"),
            is_current_month: current_start == current_fiscal_start,
            income: income,
            expenses: expenses,
            net: income - expenses
          }

          current_start = family.budget_period_end_for(current_start) + 1.day
        end
      else
        # Calendar month iteration
        current_month = @start_date.beginning_of_month
        end_of_period = @end_date.end_of_month

        while current_month <= end_of_period
          month_start = current_month
          month_end = current_month.end_of_month

          # Ensure we don't go beyond the end date
          month_end = @end_date if month_end > @end_date

          period = Period.custom(start_date: month_start, end_date: month_end)

          income = income_statement.income_totals(period: period).total
          expenses = income_statement.expense_totals(period: period).total

          trends << {
            month: month_start.strftime("%b %Y"),
            is_current_month: (month_start.month == Date.current.month && month_start.year == Date.current.year),
            income: income,
            expenses: expenses,
            net: income - expenses
          }

          current_month = current_month.next_month
        end
      end

      trends
    end

    def build_transactions_breakdown
      # Base query: all transactions in the period
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id }).merge(Account.visible)
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: :parent)

      # Apply filters
      transactions = apply_transaction_filters(transactions)

      # Get trades in the period (matching income_statement logic)
      trades = Trade
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id }).merge(Account.visible)
        .where(entries: { entryable_type: "Trade", excluded: false, date: @period.date_range })
        .includes(entry: :account)

      # The account, amount and date filters apply to trades too; a category or tag
      # filter leaves them out, since a trade has neither
      trades = apply_trade_filters(trades)

      # Get sort parameters. The table sorts by amount only.
      sort_direction = %w[asc desc].include?(params[:sort_direction]) ? params[:sort_direction] : "desc"

      # Group by category (tracking parent relationship) and type
      # Structure: { [parent_category_id, type] => { parent_data, subcategories: { subcategory_id => data } } }
      grouped_data = {}
      family_currency = Current.family.currency

      # Helper to initialize a category group hash
      # filter_value is the transactions filter (q[categories][]) the row links to, nil when
      # the row has no category to filter by. has_transactions is false for a row that
      # only holds trades: /transactions does not list trades, so such a row gets no link.
      init_category_group = ->(id, name, color, icon, type, filter_value) do
        {
          category_id: id,
          category_name: name,
          category_color: color,
          category_icon: icon,
          type: type,
          total: 0,
          count: 0,
          filter_value: filter_value,
          has_transactions: false,
          subcategories: {}
        }
      end

      # Helper to initialize a subcategory hash
      init_subcategory = ->(category) do
        {
          category_id: category.id,
          category_name: category.name,
          category_color: category.color,
          category_icon: category.lucide_icon,
          total: 0,
          count: 0,
          filter_value: category.filter_value,
          has_transactions: false
        }
      end

      # Helper to process an entry (transaction or trade)
      process_entry = ->(category, entry, is_trade) do
        type = entry.amount > 0 ? "expense" : "income"
        # At the entry's own date; an amount with no rate at all is left out, not counted at 1
        converted = ExchangeRate.convert_or_leave_out(
          Money.new(entry.amount.abs, entry.currency), to: family_currency, date: entry.date,
          source: "ReportsController#build_transactions_breakdown", family: Current.family
        )
        next if converted.nil?

        converted_amount = converted.amount

        if category.nil?
          # Uncategorized or Other Investments (for trades)
          if is_trade
            parent_key = [ :other_investments, type ]
            grouped_data[parent_key] ||= init_category_group.call(:other_investments, Category.other_investments.name, Category.other_investments.color, Category.other_investments.lucide_icon, type, nil)
          else
            parent_key = [ :uncategorized, type ]
            grouped_data[parent_key] ||= init_category_group.call(:uncategorized, Category.uncategorized.name, Category.uncategorized.color, Category.uncategorized.lucide_icon, type, Category::UNCATEGORIZED_FILTER_VALUE)
          end
        elsif category.parent_id.present?
          # This is a subcategory - group under parent
          parent = category.parent
          parent_key = [ parent.id, type ]
          grouped_data[parent_key] ||= init_category_group.call(parent.id, parent.name, parent.color || Category::UNCATEGORIZED_COLOR, parent.lucide_icon, type, parent.filter_value)

          # Add to subcategory
          grouped_data[parent_key][:subcategories][category.id] ||= init_subcategory.call(category)
          grouped_data[parent_key][:subcategories][category.id][:count] += 1
          grouped_data[parent_key][:subcategories][category.id][:total] += converted_amount
          grouped_data[parent_key][:subcategories][category.id][:has_transactions] = true unless is_trade
        else
          # This is a root category (no parent)
          parent_key = [ category.id, type ]
          grouped_data[parent_key] ||= init_category_group.call(category.id, category.name, category.color || Category::UNCATEGORIZED_COLOR, category.lucide_icon, type, category.filter_value)
        end

        grouped_data[parent_key][:count] += 1
        grouped_data[parent_key][:total] += converted_amount
        grouped_data[parent_key][:has_transactions] = true unless is_trade
      end

      # Process transactions
      transactions.each do |transaction|
        process_entry.call(transaction.category, transaction.entry, false)
      end

      # Process trades. A trade has no category: it lands in Other Investments.
      trades.each do |trade|
        process_entry.call(nil, trade.entry, true)
      end

      # Convert to array and sort subcategories
      result = grouped_data.values.map do |parent_data|
        subcategories = parent_data[:subcategories].values.sort_by { |s| sort_direction == "asc" ? s[:total] : -s[:total] }

        # If parent has subcategories AND direct transactions, inject synthetic "Other" entry
        if subcategories.any?
          subcategories_total = subcategories.sum { |s| s[:total] }
          direct_total = parent_data[:total] - subcategories_total

          if direct_total > 0
            direct_count = parent_data[:count] - subcategories.sum { |s| s[:count] }
            subcategories << {
              category_id: "#{parent_data[:category_id]}_other",
              category_name: I18n.t("reports.transactions_breakdown.table.other_category", category: parent_data[:category_name]),
              category_color: parent_data[:category_color],
              category_icon: parent_data[:category_icon],
              total: direct_total,
              count: [ direct_count, 1 ].max,
              # The parent's own filter also lists its subcategories, so this row has no
              # exact filter and gets no link
              filter_value: nil,
              has_transactions: parent_data[:has_transactions],
              synthetic: true
            }
            subcategories = subcategories.sort_by { |s| sort_direction == "asc" ? s[:total] : -s[:total] }
          end
        end

        parent_data.merge(subcategories: subcategories)
      end

      # Sort by amount (total) with the specified direction
      if sort_direction == "asc"
        result.sort_by { |g| g[:total] }
      else
        result.sort_by { |g| -g[:total] }
      end
    end

    def build_investment_metrics
      investment_statement = Current.family.investment_statement
      investment_accounts = investment_statement.investment_accounts

      return { has_investments: false } unless investment_accounts.any?

      period_totals = investment_statement.totals(period: @period)

      {
        has_investments: true,
        portfolio_value: investment_statement.portfolio_value_money,
        unrealized_trend: investment_statement.unrealized_gains_trend,
        period_contributions: period_totals.contributions,
        period_withdrawals: period_totals.withdrawals,
        top_holdings: investment_statement.top_holdings(limit: 5),
        # The account cards read each account's logo, provider links and subtype
        accounts: investment_accounts.preload(:accountable, account_providers: :provider).with_attached_logo.to_a,
        gains_by_tax_treatment: build_gains_by_tax_treatment(investment_statement)
      }
    end

    def build_gains_by_tax_treatment(investment_statement)
      currency = Current.family.currency
      # The statement already loaded these for the figures above; add the accountables
      # (tax_treatment reads them) in one query
      current_holdings = investment_statement.loaded_current_holdings
      ActiveRecord::Associations::Preloader.new(records: current_holdings.map(&:account).uniq, associations: :accountable).call

      # Group holdings by tax treatment (from account)
      holdings_by_treatment = current_holdings.group_by { |h| h.account.tax_treatment || :taxable }

      # Get sell trades in period with realized gains
      # Eager-load security, account, and accountable to avoid N+1
      sell_trades = Current.family.trades
        .joins(:entry)
        .where(entries: { date: @period.date_range })
        .where("trades.qty < 0")
        # A transfer out has the same negative quantity as a sale. Nothing was sold, so
        # it is neither counted nor listed as one.
        .where(
          "trades.investment_activity_label IS NULL OR trades.investment_activity_label NOT IN (?)",
          Trade::INTERNAL_MOVEMENT_LABELS
        )
        .includes(:security, entry: { account: :accountable })
        .to_a

      # Preload holdings for all accounts that have sell trades to avoid N+1 in realized_gain_loss
      account_ids = sell_trades.map { |t| t.entry.account_id }.uniq
      holdings_by_account = Holding
        .where(account_id: account_ids)
        .where("date <= ?", @period.date_range.end)
        .order(date: :desc)
        .group_by(&:account_id)

      # Inject preloaded holdings into trades for realized_gain_loss calculation
      sell_trades.each do |trade|
        trade.instance_variable_set(:@preloaded_holdings, holdings_by_account[trade.entry.account_id] || [])
      end

      # The day's rates the proceeds conversion needs, in one query rather than one per
      # foreign sale
      Trade.preload_exchange_rates(sell_trades)

      trades_by_treatment = sell_trades.group_by { |t| t.entry.account.tax_treatment || :taxable }

      # Build metrics per treatment
      %i[taxable tax_deferred tax_exempt tax_advantaged].each_with_object({}) do |treatment, hash|
        holdings = holdings_by_treatment[treatment] || []
        trades = trades_by_treatment[treatment] || []

        # Holdings and sales left out of the totals for want of an exchange rate
        unconverted = 0

        # Unrealized gains mark holdings to market, so they convert at today's rate, as the
        # rest of the card does. Only holdings with a known cost basis have a gain.
        unrealized_by_holding = {}
        unrealized = holdings.sum do |h|
          trend = h.trend
          next 0 unless trend

          converted = investment_statement.to_family_money_or_nil(trend.value)
          if converted.nil?
            unconverted += 1
            next 0
          end

          unrealized_by_holding[h.id] = converted
          converted.amount
        end

        # Realized gains are locked at the sale, so each converts at its own date. The gain
        # is in the currency the position's basis is carried in (Trade#realized_gain_loss
        # converts the proceeds into it first), so it converts from that currency.
        realized_by_trade = trades.each_with_object({}) do |t, memo|
          gain = t.realized_gain_loss

          if gain.nil?
            # A sale with no rate between its own two currencies is left out and counted;
            # one with no cost basis never had a figure
            unconverted += 1 if t.realized_gain_unconvertible?
            next
          end

          converted = ExchangeRate.convert_or_leave_out(
            gain.value, to: currency, date: t.entry.date, source: "ReportsController#gains_by_tax_treatment", family: Current.family
          )

          if converted.nil?
            unconverted += 1
            next
          end

          memo[t.id] = converted
        end

        realized = realized_by_trade.values.sum(BigDecimal("0"), &:amount)

        # Only include treatment groups that have some activity
        next if holdings.empty? && trades.empty?

        hash[treatment] = {
          holdings: holdings,
          sell_trades: trades,
          unrealized_gain: Money.new(unrealized, currency),
          realized_gain: Money.new(realized, currency),
          # Per-line figures in family currency, so the lines under the card and its totals
          # are the same arithmetic. A line with no rate has no entry and says so.
          realized_gain_by_trade: realized_by_trade,
          unrealized_gain_by_holding: unrealized_by_holding,
          unconverted_count: unconverted,
          total_gain: Money.new(unrealized + realized, currency)
        }
      end
    end

    def build_net_worth_metrics
      balance_sheet = Current.family.balance_sheet
      currency = Current.family.currency

      # Current net worth
      current_net_worth = balance_sheet.net_worth
      total_assets = balance_sheet.assets.total
      total_liabilities = balance_sheet.liabilities.total

      # Get net worth series for the period to calculate change
      # The series.trend gives us the change from first to last value in the period
      net_worth_series = balance_sheet.net_worth_series(period: @period)
      trend = net_worth_series&.trend

      # Get asset and liability groups for breakdown
      asset_groups = balance_sheet.assets.account_groups.map do |group|
        { name: group.name, total: Money.new(group.total, currency) }
      end.reject { |g| g[:total].zero? }

      liability_groups = balance_sheet.liabilities.account_groups.map do |group|
        { name: group.name, total: Money.new(group.total, currency) }
      end.reject { |g| g[:total].zero? }

      # Monthly net worth with the account group balances, for the chart tooltip
      breakdown_series = balance_sheet.net_worth_breakdown_series(period: @period)

      {
        current_net_worth: Money.new(current_net_worth, currency),
        total_assets: Money.new(total_assets, currency),
        total_liabilities: Money.new(total_liabilities, currency),
        trend: trend,
        asset_groups: asset_groups,
        liability_groups: liability_groups,
        breakdown_series: breakdown_series
      }
    end

    def apply_transaction_filters(transactions)
      # Filter by category (including subcategories)
      if params[:filter_category_id].present?
        category_id = params[:filter_category_id]
        # Scope to family's categories to prevent cross-family data access
        subcategory_ids = Current.family.categories.where(parent_id: category_id).pluck(:id)
        all_category_ids = [ category_id ] + subcategory_ids
        transactions = transactions.where(category_id: all_category_ids)
      end

      # Filter by tag
      if params[:filter_tag_id].present?
        transactions = transactions.joins(:taggings).where(taggings: { tag_id: params[:filter_tag_id] })
      end

      apply_entry_filters(transactions)
    end

    # Trades have no category and no tags, so either filter leaves them all out
    def apply_trade_filters(trades)
      return trades.none if params[:filter_category_id].present? || params[:filter_tag_id].present?

      apply_entry_filters(trades)
    end

    # The filters every entry has: account, amount range and dates within the period
    def apply_entry_filters(scope)
      # Filter by account
      if params[:filter_account_id].present?
        scope = scope.where(entries: { account_id: params[:filter_account_id] })
      end

      # Filter by amount range
      if params[:filter_amount_min].present?
        scope = scope.where("ABS(entries.amount) >= ?", params[:filter_amount_min].to_f)
      end

      if params[:filter_amount_max].present?
        scope = scope.where("ABS(entries.amount) <= ?", params[:filter_amount_max].to_f)
      end

      # Filter by date range (within the period). A bad date is ignored on its own, so
      # the other filters still apply.
      filter_start = parse_filter_date(:filter_date_start)
      scope = scope.where("entries.date >= ?", filter_start) if filter_start && filter_start >= @start_date

      filter_end = parse_filter_date(:filter_date_end)
      scope = scope.where("entries.date <= ?", filter_end) if filter_end && filter_end <= @end_date

      scope
    end

    def parse_filter_date(param_name)
      return nil if params[param_name].blank?

      Date.parse(params[param_name].to_s)
    rescue Date::Error
      nil
    end

    def build_transactions_breakdown_for_export
      # Get flat transactions list (not grouped) for export
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id }).merge(Account.visible)
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: [])

      transactions = apply_transaction_filters(transactions)

      sort_by = params[:sort_by] || "date"
      # Whitelist sort_direction to prevent SQL injection
      sort_direction = %w[asc desc].include?(params[:sort_direction]&.downcase) ? params[:sort_direction].upcase : "DESC"

      case sort_by
      when "date"
        transactions.order("entries.date #{sort_direction}")
      when "amount"
        transactions.order("entries.amount #{sort_direction}")
      else
        transactions.order("entries.date DESC")
      end
    end

    def build_monthly_breakdown_for_export
      use_fiscal = @fiscal_mode == "true" && Current.family.fiscal_month_enabled?
      family = Current.family

      # Generate list of months in the period
      months = []
      if use_fiscal
        current_start = family.budget_period_start_for(@start_date)
        while current_start <= @end_date
          months << current_start
          current_start = family.budget_period_end_for(current_start) + 1.day
        end
      else
        current_month = @start_date.beginning_of_month
        end_of_period = @end_date.end_of_month
        while current_month <= end_of_period
          months << current_month
          current_month = current_month.next_month
        end
      end

      # Get all transactions in the period
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: family.id }).merge(Account.visible)
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: [])

      transactions = apply_transaction_filters(transactions)

      # Group by category, type, and month
      breakdown = {}
      family_currency = family.currency

      # Process transactions
      transactions.each do |transaction|
        entry = transaction.entry
        is_expense = entry.amount > 0
        type = is_expense ? "expense" : "income"
        category_name = transaction.category&.name || "Uncategorized"
        month_key = use_fiscal ? family.budget_period_start_for(entry.date) : entry.date.beginning_of_month

        # Convert to family currency at the entry's own date; an amount with no rate at all is
        # left out, not counted at 1
        converted = ExchangeRate.convert_or_leave_out(
          Money.new(entry.amount.abs, entry.currency), to: family_currency, date: entry.date,
          source: "ReportsController#monthly_breakdown_for_export", family: family
        )
        next if converted.nil?

        converted_amount = converted.amount

        key = [ category_name, type ]
        breakdown[key] ||= { category: category_name, type: type, months: {}, total: 0 }
        breakdown[key][:months][month_key] ||= 0
        breakdown[key][:months][month_key] += converted_amount
        breakdown[key][:total] += converted_amount
      end

      # Convert to array and sort by type and total (descending)
      result = breakdown.map do |key, data|
        {
          category: data[:category],
          type: data[:type],
          months: data[:months],
          total: data[:total]
        }
      end

      # Separate and sort income and expenses
      income_data = result.select { |r| r[:type] == "income" }.sort_by { |r| -r[:total] }
      expense_data = result.select { |r| r[:type] == "expense" }.sort_by { |r| -r[:total] }

      {
        months: months,
        income: income_data,
        expenses: expense_data
      }
    end

    def generate_transactions_csv
      require "csv"

      CSV.generate do |csv|
        # Build header row: Category + Month columns + Total
        month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
        header_row = [ "Category" ] + month_headers + [ "Total" ]
        csv << header_row

        # Income section
        if @export_data[:income].any?
          csv << [ "INCOME" ] + Array.new(month_headers.length + 1, "")

          @export_data[:income].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            csv << row
          end

          # Income totals row
          totals_row = [ "TOTAL INCOME" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_income_total = @export_data[:income].sum { |c| c[:total] }
          totals_row << Money.new(grand_income_total, Current.family.currency).format
          csv << totals_row

          # Blank row
          csv << []
        end

        # Expenses section
        if @export_data[:expenses].any?
          csv << [ "EXPENSES" ] + Array.new(month_headers.length + 1, "")

          @export_data[:expenses].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            csv << row
          end

          # Expenses totals row
          totals_row = [ "TOTAL EXPENSES" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
          totals_row << Money.new(grand_expenses_total, Current.family.currency).format
          csv << totals_row
        end
      end
    end

    def generate_transactions_xlsx
      require "caxlsx"

      package = Axlsx::Package.new
      workbook = package.workbook
      bold_style = workbook.styles.add_style(b: true)

      workbook.add_worksheet(name: "Breakdown") do |sheet|
        # Build header row: Category + Month columns + Total
        month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
        header_row = [ "Category" ] + month_headers + [ "Total" ]
        sheet.add_row header_row, style: bold_style

        # Income section
        if @export_data[:income].any?
          sheet.add_row [ "INCOME" ] + Array.new(month_headers.length + 1, ""), style: bold_style

          @export_data[:income].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            sheet.add_row row
          end

          # Income totals row
          totals_row = [ "TOTAL INCOME" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_income_total = @export_data[:income].sum { |c| c[:total] }
          totals_row << Money.new(grand_income_total, Current.family.currency).format
          sheet.add_row totals_row, style: bold_style

          # Blank row
          sheet.add_row []
        end

        # Expenses section
        if @export_data[:expenses].any?
          sheet.add_row [ "EXPENSES" ] + Array.new(month_headers.length + 1, ""), style: bold_style

          @export_data[:expenses].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            sheet.add_row row
          end

          # Expenses totals row
          totals_row = [ "TOTAL EXPENSES" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
          totals_row << Money.new(grand_expenses_total, Current.family.currency).format
          sheet.add_row totals_row, style: bold_style
        end
      end

      package.to_stream.read
    end

    def generate_transactions_pdf
      require "prawn"

      Prawn::Document.new(page_layout: :landscape) do |pdf|
        pdf.text "Transaction Breakdown Report", size: 20, style: :bold
        pdf.text "Period: #{@start_date.strftime('%b %-d, %Y')} to #{@end_date.strftime('%b %-d, %Y')}", size: 12
        pdf.move_down 20

        if @export_data[:income].any? || @export_data[:expenses].any?
          # Build header row
          month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
          header_row = [ "Category" ] + month_headers + [ "Total" ]

          # Income section
          if @export_data[:income].any?
            pdf.text "INCOME", size: 14, style: :bold
            pdf.move_down 10

            income_table_data = [ header_row ]

            @export_data[:income].each do |category_data|
              row = [ category_data[:category] ]

              @export_data[:months].each do |month|
                amount = category_data[:months][month] || 0
                row << Money.new(amount, Current.family.currency).format
              end

              row << Money.new(category_data[:total], Current.family.currency).format
              income_table_data << row
            end

            # Income totals row
            totals_row = [ "TOTAL INCOME" ]
            @export_data[:months].each do |month|
              month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
              totals_row << Money.new(month_total, Current.family.currency).format
            end
            grand_income_total = @export_data[:income].sum { |c| c[:total] }
            totals_row << Money.new(grand_income_total, Current.family.currency).format
            income_table_data << totals_row

            pdf.table(income_table_data, header: true, width: pdf.bounds.width, cell_style: { size: 8 }) do
              row(0).font_style = :bold
              row(0).background_color = "CCFFCC"
              row(-1).font_style = :bold
              row(-1).background_color = "99FF99"
              columns(0).align = :left
              columns(1..-1).align = :right
              self.row_colors = [ "FFFFFF", "F9F9F9" ]
            end

            pdf.move_down 20
          end

          # Expenses section
          if @export_data[:expenses].any?
            pdf.text "EXPENSES", size: 14, style: :bold
            pdf.move_down 10

            expenses_table_data = [ header_row ]

            @export_data[:expenses].each do |category_data|
              row = [ category_data[:category] ]

              @export_data[:months].each do |month|
                amount = category_data[:months][month] || 0
                row << Money.new(amount, Current.family.currency).format
              end

              row << Money.new(category_data[:total], Current.family.currency).format
              expenses_table_data << row
            end

            # Expenses totals row
            totals_row = [ "TOTAL EXPENSES" ]
            @export_data[:months].each do |month|
              month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
              totals_row << Money.new(month_total, Current.family.currency).format
            end
            grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
            totals_row << Money.new(grand_expenses_total, Current.family.currency).format
            expenses_table_data << totals_row

            pdf.table(expenses_table_data, header: true, width: pdf.bounds.width, cell_style: { size: 8 }) do
              row(0).font_style = :bold
              row(0).background_color = "FFCCCC"
              row(-1).font_style = :bold
              row(-1).background_color = "FF9999"
              columns(0).align = :left
              columns(1..-1).align = :right
              self.row_colors = [ "FFFFFF", "F9F9F9" ]
            end
          end
        else
          pdf.text "No transactions found for this period.", size: 12
        end
      end.render
    end

    # Export Authentication - handles both session and API key auth
    def authenticate_for_export
      if api_key_present?
        # Use API key authentication
        authenticate_with_api_key
      else
        # Use normal session authentication
        authenticate_user!
      end
    end

    # API Key Authentication Methods
    def api_key_present?
      params[:api_key].present? || request.headers["X-Api-Key"].present?
    end

    def authenticate_with_api_key
      api_key_value = params[:api_key] || request.headers["X-Api-Key"]

      unless api_key_value
        render plain: "API key is required", status: :unauthorized
        return false
      end

      @api_key = ApiKey.find_by_value(api_key_value)

      unless @api_key && @api_key.active? && @api_key.user.active?
        render plain: "Invalid or expired API key", status: :unauthorized
        return false
      end

      # Check if API key has read permissions
      unless @api_key.scopes&.include?("read") || @api_key.scopes&.include?("read_write")
        render plain: "API key does not have read permission", status: :forbidden
        return false
      end

      # Set up the current user and session context
      @current_user = @api_key.user
      @api_key.update_last_used!

      # Set up Current context for API requests (similar to Api::V1::BaseController)
      # Return false if setup fails to halt the filter chain
      return false unless setup_current_context_for_api_key

      true
    end

    def setup_current_context_for_api_key
      unless @current_user
        render plain: "User not found for API key", status: :internal_server_error
        return false
      end

      Current.session = Session.ephemeral_for(@current_user, request)

      # Verify the delegation chain works
      unless Current.user
        render plain: "Failed to establish user context", status: :internal_server_error
        return false
      end

      # Ensure we have a valid family context
      unless Current.family
        render plain: "User does not have an associated family", status: :internal_server_error
        return false
      end

      true
    end
end
