# One budget period as the budget page shows it: the total, what is given to categories, and per category the
# budgeted amount, the spending (net of refunds) and what is left, all in the family currency. Fork-native take
# on upstream 7685650e6: the period comes from the family's fiscal months, and there are no personal budgets.
#
# Like the budget page, a visit to a month with no budget row yet creates an empty one (Budget.find_or_bootstrap)
# and adds a row for each expense category.
class Assistant::Function::GetBudget < Assistant::Function
  include Assistant::Function::BudgetSupport

  class << self
    def name
      "get_budget"
    end

    def description
      <<~INSTRUCTIONS
        Shows one budget period: the total budgeted spending, the amount given to
        categories, the spending so far and what is left, then each expense
        category (subcategories under their parent) with its budgeted amount,
        actual spending and the amount available. Spending is net of refunds in
        the same category. Amounts are numbers in the family currency.

        month picks the period (default: the current one). With fiscal months
        on, a period starts on the family's fiscal start day, so "2026-03" with
        start day 25 is Mar 25 to Apr 24, and "2026-03-10" is the period that
        contains Mar 10 (Feb 25 to Mar 24).

        initialized: false means no total is set yet. A subcategory with
        inherits_parent_budget: true has no amount of its own and spends from
        its parent's amount. Change amounts with update_budget.

        rollover_enabled: true means the category keeps its unspent money from
        one period to the next; rolled_over_amount is what it carried in from
        the period before (never below 0: an overspend carries nothing). It is
        added to what the category can spend (available counts it), not to
        budgeted. A parent's rolled_over_amount includes its subcategories'.
        totals.rolled_over is the carry of all categories. The carry is as of
        the last visit of the budget page.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        month: { type: [ "string", "null" ], description: MONTH_DESCRIPTION }
      }
    )
  end

  def call(params = {})
    period_start = budget_period_start(params["month"])
    error = budget_month_error(params["month"], period_start)
    return error if error

    budget_payload(Budget.find_or_bootstrap(family, start_date: period_start))
  end

  private
    def budget_payload(budget)
      current = budget.current?

      {
        currency: family.currency,
        month: budget.to_param,
        period: { start_date: budget.start_date.iso8601, end_date: budget.end_date.iso8601 },
        is_current: current,
        days_left: current ? (budget.end_date - Date.current).to_i + 1 : nil,
        initialized: budget.initialized?,
        allocation_state: budget.allocation_state.to_s,
        totals: {
          budgeted_spending: budget.budgeted_spending && budget_amount(budget.budgeted_spending),
          allocated_spending: budget_amount(budget.allocated_spending),
          available_to_allocate: budget_amount(budget.available_to_allocate),
          actual_spending: budget_amount(budget.actual_spending),
          available_to_spend: budget_amount(budget.available_to_spend),
          percent_spent: budget_percent(budget.initialized? ? budget.percent_of_budget_spent : 0),
          rolled_over: budget_amount(budget.total_rolled_over)
        },
        income: {
          expected_income: budget.expected_income && budget_amount(budget.expected_income),
          actual_income: budget_amount(budget.actual_income)
        },
        categories: BudgetCategory::Group.for(budget.budget_categories).map { |group| group_payload(group) },
        uncategorized: uncategorized_payload(budget)
      }.compact
    end

    def group_payload(group)
      category_payload(group.budget_category).merge(
        subcategories: group.budget_subcategories.map do |subcategory|
          category_payload(subcategory).merge(inherits_parent_budget: subcategory.inherits_parent_budget?)
        end
      )
    end

    # id is the budget row (this period only); category_id is what update_budget takes
    def category_payload(budget_category)
      {
        id: budget_category.id,
        category_id: budget_category.category_id,
        name: budget_category.name,
        budgeted: budget_amount(budget_category.display_budgeted_spending),
        actual: budget_amount(budget_category.actual_spending),
        available: budget_amount(budget_category.available_to_spend),
        percent_spent: budget_percent(budget_category.percent_of_budget_spent || 0),
        status: category_status(budget_category),
        rollover_enabled: budget_category.rollover_enabled?,
        rolled_over_amount: budget_amount(budget_category.display_rolled_over_amount)
      }
    end

    # Spending with no category, set against what is not given to categories. Left out when nothing was spent.
    def uncategorized_payload(budget)
      row = budget.uncategorized_budget_category
      spent = row.actual_spending
      return nil unless spent.positive?

      {
        name: row.name,
        budgeted: budget_amount(row[:budgeted_spending]),
        actual: budget_amount(spent),
        available: budget_amount(row.available_to_spend)
      }
    end

    def category_status(budget_category)
      return "over_budget" if budget_category.over_budget_with_budget?
      return "unbudgeted_spending" if budget_category.unbudgeted_with_spending?
      return "near_limit" if budget_category.budgeted? && budget_category.near_limit?
      return "on_track" if budget_category.on_track?

      "no_activity"
    end
end
