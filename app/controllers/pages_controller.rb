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

    family_currency = Current.family.currency

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

    # Toggle: show/hide subcategories in Sankey (default: false)
    @cashflow_show_subcategories = if params.key?(:cashflow_show_subcategories)
      ActiveModel::Type::Boolean.new.cast(params[:cashflow_show_subcategories])
    else
      false
    end

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    income_totals = Current.family.income_statement.income_totals(period: @cashflow_period)
    expense_totals = Current.family.income_statement.expense_totals(period: @cashflow_period)

    # Build both variants for use in fullscreen overlay controls
    @cashflow_sankey_data_with_subcategories = build_cashflow_sankey_data(
      income_totals,
      expense_totals,
      family_currency,
      include_subcategories: true
    )

    @cashflow_sankey_data_without_subcategories = build_cashflow_sankey_data(
      income_totals,
      expense_totals,
      family_currency,
      include_subcategories: false
    )

    # Choose the currently selected dataset for compact view
    @cashflow_sankey_data = @cashflow_show_subcategories ?
      @cashflow_sankey_data_with_subcategories :
      @cashflow_sankey_data_without_subcategories

    # Outflows uses its own period
    outflows_expense_totals = Current.family.income_statement.expense_totals(period: @outflows_period)
    @outflows_data = build_outflows_donut_data(outflows_expense_totals)

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

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/we-promise/sure/releases' target='_blank'>GitHub releases page</a> directly.</p>"
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  private
    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections]
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order]
      end
    end

    def build_dashboard_sections
      all_sections = [
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          locals: { sankey_data: @cashflow_sankey_data, period: @cashflow_period },
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
          locals: { investment_statement: @investment_statement, period: @period },
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

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(income_totals, expense_totals, currency, include_subcategories: true)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income = income_totals.total.to_f.round(2)
      total_expense = expense_totals.total.to_f.round(2)
      total_income_val = total_income
      total_expense_val = total_expense

      # Central Cash Flow node
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

      # --- Process Income Side ---
      if include_subcategories
        # Parent categories + subcategories
        grouped_income_totals = income_totals.category_totals.group_by { |ct| ct.category.parent_id }
        root_income_totals = grouped_income_totals[nil] || []

        root_income_totals.each do |ct|
          val = ct.total.to_f.round(2)
          next if val.zero?

          percentage_of_total_income = total_income_val.zero? ? 0 : (val / total_income_val * 100).round(1)

          node_display_name = ct.category.name
          node_color = ct.category.color.presence || Category::COLORS.sample

          # Parent income category node
          parent_idx = add_node.call(
            "income_#{ct.category.id}",
            node_display_name,
            val,
            percentage_of_total_income,
            node_color
          )

          # Link: Parent category -> Cash Flow (income flows into cash flow)
          links << {
            source: parent_idx,
            target: cash_flow_idx,
            value: val,
            color: node_color,
            percentage: percentage_of_total_income
          }

          # Subcategories for this parent (skip for Uncategorized which has no true children)
          subcategory_totals = node_display_name == "Uncategorized" ? [] : (grouped_income_totals[ct.category.id] || [])
          subcategory_totals.each do |st|
            sub_val = st.total.to_f.round(2)
            next if sub_val.zero?

            sub_percentage = total_income_val.zero? ? 0 : (sub_val / total_income_val * 100).round(1)
            sub_node_color = st.category.color.presence || node_color

            sub_idx = add_node.call(
              "income_#{st.category.id}",
              st.category.name,
              sub_val,
              sub_percentage,
              sub_node_color
            )

            # Link: Subcategory -> Parent category
            links << {
              source: sub_idx,
              target: parent_idx,
              value: sub_val,
              color: sub_node_color,
              percentage: sub_percentage
            }
          end

          # If the parent has direct transactions not assigned to subcategories,
          # show them as a "Direct" leaf to preserve Sankey flow conservation.
          if subcategory_totals.any?
            sum_sub = subcategory_totals.sum { |st| st.total.to_f.round(2) }
            direct_val = (val - sum_sub).round(2)
            if direct_val.positive?
              direct_percentage = total_income_val.zero? ? 0 : (direct_val / total_income_val * 100).round(1)
              direct_idx = add_node.call(
                "income_#{ct.category.id}_direct",
                "#{node_display_name} (Direct)",
                direct_val,
                direct_percentage,
                node_color
              )
              links << {
                source: direct_idx,
                target: parent_idx,
                value: direct_val,
                color: node_color,
                percentage: direct_percentage
              }
            end
          end
        end
      else
        # Top-level categories only
        income_totals.category_totals.each do |ct|
          # Skip subcategories – only include root income categories
          next if ct.category.parent_id.present?

          val = ct.total.to_f.round(2)
          next if val.zero?

          percentage_of_total_income = total_income_val.zero? ? 0 : (val / total_income_val * 100).round(1)

          node_display_name = ct.category.name
          node_color = ct.category.color.presence || Category::COLORS.sample

          current_cat_idx = add_node.call(
            "income_#{ct.category.id}",
            node_display_name,
            val,
            percentage_of_total_income,
            node_color
          )

          links << {
            source: current_cat_idx,
            target: cash_flow_idx,
            value: val,
            color: node_color,
            percentage: percentage_of_total_income
          }
        end
      end

      if include_subcategories
        # --- Process Expense Side (Parent categories + subcategories) ---
        # Group expense category totals by parent_id to build a hierarchy
        grouped_expense_totals = expense_totals.category_totals.group_by { |ct| ct.category.parent_id }
        root_expense_totals = grouped_expense_totals[nil] || []

        root_expense_totals.each do |ct|
          val = ct.total.to_f.round(2)
          next if val.zero?

          percentage_of_total_expense = total_expense_val.zero? ? 0 : (val / total_expense_val * 100).round(1)

          node_display_name = ct.category.name
          node_color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

          # Parent category node
          parent_idx = add_node.call(
            "expense_#{ct.category.id}",
            node_display_name,
            val,
            percentage_of_total_expense,
            node_color
          )

          # Link: Cash Flow -> Parent category
          links << {
            source: cash_flow_idx,
            target: parent_idx,
            value: val,
            color: node_color,
            percentage: percentage_of_total_expense
          }

          # Subcategories for this parent (skip for Uncategorized which has no true children)
          subcategory_totals = node_display_name == "Uncategorized" ? [] : (grouped_expense_totals[ct.category.id] || [])
          subcategory_totals.each do |st|
            sub_val = st.total.to_f.round(2)
            next if sub_val.zero?

            sub_percentage = total_expense_val.zero? ? 0 : (sub_val / total_expense_val * 100).round(1)
            sub_node_color = st.category.color.presence || node_color

            sub_idx = add_node.call(
              "expense_#{st.category.id}",
              st.category.name,
              sub_val,
              sub_percentage,
              sub_node_color
            )

            # Link: Parent category -> Subcategory
            links << {
              source: parent_idx,
              target: sub_idx,
              value: sub_val,
              color: sub_node_color,
              percentage: sub_percentage
            }
          end

          # If the parent has direct transactions not assigned to subcategories,
          # show them as a "Direct" leaf to preserve Sankey flow conservation.
          if subcategory_totals.any?
            sum_sub = subcategory_totals.sum { |st| st.total.to_f.round(2) }
            direct_val = (val - sum_sub).round(2)
            if direct_val.positive?
              direct_percentage = total_expense_val.zero? ? 0 : (direct_val / total_expense_val * 100).round(1)
              direct_idx = add_node.call(
                "expense_#{ct.category.id}_direct",
                "#{node_display_name} (Direct)",
                direct_val,
                direct_percentage,
                node_color
              )
              links << {
                source: parent_idx,
                target: direct_idx,
                value: direct_val,
                color: node_color,
                percentage: direct_percentage
              }
            end
          end
        end
      else
        # --- Process Expense Side (Top-level categories only) ---
        expense_totals.category_totals.each do |ct|
          # Only include root expense categories
          next if ct.category.parent_id.present?

          val = ct.total.to_f.round(2)
          next if val.zero?

          percentage_of_total_expense = total_expense_val.zero? ? 0 : (val / total_expense_val * 100).round(1)

          node_display_name = ct.category.name
          node_color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

          current_cat_idx = add_node.call(
            "expense_#{ct.category.id}",
            node_display_name,
            val,
            percentage_of_total_expense,
            node_color
          )

          links << {
            source: cash_flow_idx,
            target: current_cat_idx,
            value: val,
            color: node_color,
            percentage: percentage_of_total_expense
          }
        end
      end

      # --- Process Surplus ---
      leftover = (total_income_val - total_expense_val).round(2)
      if leftover.positive?
        percentage_of_total_income_for_surplus = total_income_val.zero? ? 0 : (leftover / total_income_val * 100).round(1)
        surplus_idx = add_node.call("surplus_node", "Surplus", leftover, percentage_of_total_income_for_surplus, "var(--color-success)")
        links << { source: cash_flow_idx, target: surplus_idx, value: leftover, color: "var(--color-success)", percentage: percentage_of_total_income_for_surplus }
      end

      # Update Cash Flow and Income node percentages (relative to total income)
      if node_indices["cash_flow_node"]
        nodes[node_indices["cash_flow_node"]][:percentage] = 100.0
      end
      # No primary income node anymore, percentages are on individual income cats relative to total_income_val

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
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
end
