class Assistant::Function::GetIncomeStatement < Assistant::Function
  include ActiveSupport::NumberHelper

  MAX_MONTH_BUCKETS = 36

  class << self
    def name
      "get_income_statement"
    end

    def description
      <<~INSTRUCTIONS
        Use this to get income and expense insights by category, for a specific time period

        This is great for answering questions like:
        - What is the user's net income for the current month?
        - What are the user's spending habits?
        - How much income or spending did the user have over a specific time period?

        The totals are the ones the Sure dashboard and budgets show: transfers
        between the user's own accounts, one-time items and excluded
        transactions are left out, pending transactions are not counted yet.
        Accounts the user excluded from reports (excluded_from_reports in
        get_accounts) are never counted.

        Spending trends and comparisons:
        - Month over month: pass group_by: "month" for a monthly_series. Months
          are the family's budget months (they start on the family's fiscal
          start day when one is set, else on the 1st).
        - Versus the prior period: pass compare_previous_period: true
        - Per account: pass account_ids from get_accounts (totals only; the
          category breakdown is family-wide and is omitted with this filter)

        Simple example:

        ```
        get_income_statement({
          start_date: "2024-01-01",
          end_date: "2024-12-31"
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "start_date", "end_date" ],
      properties: {
        start_date: {
          type: "string",
          description: "Start date for aggregation period in YYYY-MM-DD format"
        },
        end_date: {
          type: "string",
          description: "End date for aggregation period in YYYY-MM-DD format"
        },
        account_ids: {
          type: "array",
          description: "Account UUIDs from get_accounts; scopes totals to those accounts and omits the category breakdown",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        group_by: {
          type: "string",
          enum: [ "none", "month" ],
          description: "Pass \"month\" to add a monthly_series of income/expenses/net per budget month"
        },
        compare_previous_period: {
          type: "boolean",
          description: "Adds totals for the equal-length period immediately before start_date, with deltas"
        }
      }
    )
  end

  def call(params = {})
    period = Period.custom(start_date: Date.iso8601(params["start_date"].to_s), end_date: Date.iso8601(params["end_date"].to_s))

    account_ids = Array(params["account_ids"]).presence
    if account_ids
      unknown_ids = account_ids.uniq - eligible_accounts.where(id: account_ids.select { |id| valid_uuid?(id) }).pluck(:id)

      if unknown_ids.any?
        return tool_error(
          "unknown_account_ids",
          "Some account ids were not found or are not counted in income and expenses (hidden, pending deletion or excluded from reports). Call get_accounts for ids and retry once with active accounts that are not excluded_from_reports.",
          unknown_ids: unknown_ids
        )
      end
    end

    # The bucket count is checked before any aggregation runs
    buckets = params["group_by"] == "month" ? month_buckets(period) : nil

    if buckets && buckets.size > MAX_MONTH_BUCKETS
      return tool_error("too_many_periods", "That range has more than #{MAX_MONTH_BUCKETS} monthly buckets. Use a shorter range.")
    end

    result = account_ids ? scoped_result(period, account_ids) : full_result(period)
    result[:monthly_series] = buckets.map { |bucket| bucket_totals(bucket, account_ids) } if buckets
    result[:previous_period] = previous_period_comparison(period, account_ids) if params["compare_previous_period"] == true

    result
  rescue Date::Error
    tool_error("invalid_date", "Dates must be valid and in YYYY-MM-DD format.")
  rescue ActiveModel::ValidationError
    tool_error("invalid_date", "start_date must be on or before end_date.")
  end

  private
    def income_statement
      @income_statement ||= family.income_statement
    end

    # The accounts IncomeStatement counts: the family's visible ones not excluded from reports
    def eligible_accounts
      family.accounts.visible.included_in_reports
    end

    def full_result(period)
      income_data = income_statement.income_totals(period: period)
      expense_data = income_statement.expense_totals(period: period)

      {
        currency: family.currency,
        period: {
          start_date: period.start_date,
          end_date: period.end_date
        },
        income: {
          total: format_money(income_data.total),
          by_category: to_ai_category_totals(income_data.category_totals)
        },
        expense: {
          total: format_money(expense_data.total),
          by_category: to_ai_category_totals(expense_data.category_totals)
        },
        insights: get_insights(income_data, expense_data)
      }
    end

    # Category rollups and the family medians are family-wide by construction, so a per-account view reports
    # totals only and says why the breakdown is gone.
    def scoped_result(period, account_ids)
      totals = totals_for(period, account_ids)
      income = totals.income_money.amount
      expense = totals.expense_money.amount

      {
        currency: family.currency,
        period: {
          start_date: period.start_date,
          end_date: period.end_date
        },
        account_ids: account_ids,
        income: { total: format_money(income), by_category: nil },
        expense: { total: format_money(expense), by_category: nil },
        net: format_money(income - expense),
        breakdown_omitted_reason: "category breakdown is not available with an account filter"
      }
    end

    # The same transactions income_totals and expense_totals count (visible, not pending, in the period), so a
    # bucket or an account view adds up to the full statement.
    def totals_for(period, account_ids = nil)
      scope = family.transactions.visible.excluding_pending.in_period(period)
      scope = scope.where(entries: { account_id: account_ids }) if account_ids

      income_statement.totals(transactions_scope: scope, date_range: period.date_range)
    end

    # One bucket per budget month (fiscal month when the family has one), clipped to the requested range
    def month_buckets(period)
      cursor = period.start_date

      [].tap do |buckets|
        while cursor <= period.end_date
          month_end = family.budget_period_end_for(family.budget_period_start_for(cursor))
          bucket_end = [ month_end, period.end_date ].min
          buckets << Period.custom(start_date: cursor, end_date: bucket_end)
          cursor = bucket_end + 1.day
          break if buckets.size > MAX_MONTH_BUCKETS
        end
      end
    end

    def bucket_totals(bucket, account_ids)
      totals = totals_for(bucket, account_ids)
      income = totals.income_money.amount
      expenses = totals.expense_money.amount

      {
        start_date: bucket.start_date,
        end_date: bucket.end_date,
        income: format_money(income),
        expenses: format_money(expenses),
        net: format_money(income - expenses)
      }
    end

    def previous_period_comparison(period, account_ids)
      previous = Period.custom(
        start_date: period.start_date - period.days.days,
        end_date: period.start_date - 1.day
      )
      current_totals = totals_for(period, account_ids)
      previous_totals = totals_for(previous, account_ids)

      {
        start_date: previous.start_date,
        end_date: previous.end_date,
        income: format_money(previous_totals.income_money.amount),
        expenses: format_money(previous_totals.expense_money.amount),
        net: format_money(previous_totals.income_money.amount - previous_totals.expense_money.amount),
        income_change: change_stats(previous_totals.income_money.amount, current_totals.income_money.amount),
        expenses_change: change_stats(previous_totals.expense_money.amount, current_totals.expense_money.amount)
      }
    end

    def change_stats(previous_amount, current_amount)
      delta = current_amount - previous_amount
      percent = previous_amount.zero? ? nil : ((delta / previous_amount.to_f) * 100).round(1)

      {
        amount: format_money(delta),
        percent: percent
      }
    end

    def format_money(value)
      Money.new(value, family.currency).format
    end

    def calculate_savings_rate(total_income, total_expenses)
      return 0 if total_income.zero?
      savings = total_income - total_expenses
      rate = (savings / total_income.to_f) * 100
      rate.round(2)
    end

    def to_ai_category_totals(category_totals)
      hierarchical_groups = category_totals.group_by { |ct| ct.category.parent_id }.then do |grouped|
        root_category_totals = grouped[nil] || []

        root_category_totals.each_with_object({}) do |ct, hash|
          subcategory_totals = ct.category.name == "Uncategorized" ? [] : (grouped[ct.category.id] || [])
          hash[ct.category.name] = {
            category_total: ct,
            subcategory_totals: subcategory_totals
          }
        end
      end

      # Categories with nothing in the period cost tokens and say nothing
      hierarchical_groups
        .reject { |_name, data| data.dig(:category_total).total.zero? }
        .sort_by { |_name, data| -data.dig(:category_total).total }
        .map do |name, data|
          {
            name: name,
            total: format_money(data.dig(:category_total).total),
            percentage_of_total: number_to_percentage(data.dig(:category_total).weight, precision: 1),
            subcategory_totals: data.dig(:subcategory_totals).reject { |st| st.total.zero? }.map do |st|
              {
                name: st.category.name,
                total: format_money(st.total),
                percentage_of_total: number_to_percentage(st.weight, precision: 1)
              }
            end
          }
        end
    end

    def get_insights(income_data, expense_data)
      net_income = income_data.total - expense_data.total
      savings_rate = calculate_savings_rate(income_data.total, expense_data.total)

      {
        net_income: format_money(net_income),
        savings_rate: number_to_percentage(savings_rate),
        median_monthly_income: format_money(income_statement.median_income),
        median_monthly_expenses: format_money(income_statement.median_expense),
        avg_monthly_expenses: format_money(income_statement.avg_expense)
      }
    end
end
