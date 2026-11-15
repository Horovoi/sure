# Sets one budgeted amount: the budget total, as the budget Setup step does (BudgetsController#update), or one
# expense category's amount, as the Categories step does (BudgetCategoriesController#update). Fork-native take on
# upstream 00b7252fb, one amount per call.
#
# The category amount is written to budgeted_spending directly, the same model path as the Categories step, and
# a subcategory is capped at what its parent leaves (BudgetCategory#max_allocation, the form's max). The
# envelope-budgeting unit switches this to BudgetCategory#update_budgeted_spending!, which grows the parent
# instead; that unit drops the cap here.
class Assistant::Function::UpdateBudget < Assistant::Function
  include Assistant::Function::BudgetSupport

  # Below the columns' decimal(19, 4) limit, and more than any household budget
  MAX_AMOUNT = 1_000_000_000_000

  scope_tag :write

  class << self
    def name
      "update_budget"
    end

    def description
      <<~INSTRUCTIONS
        Sets one amount of a budget period, in the family currency: the budget
        total when no category is passed, or the amount of one expense category
        (by category_id from get_budget, or its exact name). Nothing else in the
        budget changes; call it once per amount.

        A period with no total yet takes the total first; category amounts come
        after it. A subcategory's amount cannot exceed what its parent's amount
        leaves after the other subcategories; raise the parent first. The
        uncategorized row cannot be set: it is the part of the total not given
        to categories.

        month picks the period as in get_budget (default: the current one).
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "amount" ],
      properties: {
        month: { type: [ "string", "null" ], description: MONTH_DESCRIPTION },
        category: {
          type: [ "string", "null" ],
          description: "Expense category id (category_id from get_budget) or exact name; leave out to set the budget total"
        },
        amount: { type: "number", minimum: 0, description: "The new budgeted amount, in the family currency" }
      }
    )
  end

  # "Budget" when the call set the total, "BudgetCategory" when it set a category amount
  def record_type
    @record_type || "BudgetCategory"
  end

  def idempotent?
    true
  end

  def audit_before(params)
    period_start = budget_period_start(params["month"])
    budget = period_start && existing_budget(period_start)
    return nil unless budget
    return budget_snapshot(budget) if params["category"].blank?

    category = find_family_category(params["category"])
    budget_category = category && budget.all_budget_categories.find_by(category_id: category.id)
    budget_category && budget_category_snapshot(budget_category, budget)
  end

  def call(params = {})
    @record_type = nil

    amount, error = parse_amount(params["amount"])
    return error if error

    period_start = budget_period_start(params["month"])
    error = budget_month_error(params["month"], period_start)
    return error if error

    category = nil
    if params["category"].present?
      category, error = find_expense_category(params["category"])
      return error if error
    end

    result = nil

    # The bootstrap and the write share one transaction, so a failed write leaves no new budget behind
    Budget.transaction(requires_new: true) do
      budget = Budget.find_or_bootstrap(family, start_date: period_start)
      result = category ? set_category_amount(budget, category, amount) : set_total(budget, amount)
      raise ActiveRecord::Rollback if result[:error]
    end

    result
  end

  private
    def set_total(budget, amount)
      attributes = { budgeted_spending: amount }
      # A budget without expected income breaks the income summary on the budget page (see BudgetsController)
      attributes[:expected_income] = 0 if budget.expected_income.nil?

      budget.update!(attributes)
      @record_type = "Budget"

      { id: budget.id, updated: true, budget: budget_snapshot(budget), totals: totals(budget) }
    end

    def set_category_amount(budget, category, amount)
      unless budget.initialized?
        return tool_error("budget_not_set_up", "This period has no total yet. Call update_budget without category to set the total first.", month: budget.to_param)
      end

      budget_category = budget.budget_categories.find_by(category_id: category.id)
      return tool_error("category_not_in_budget", "Use a category_id from get_budget for this month.") unless budget_category

      max = budget_category.max_allocation
      if max && amount > max
        return tool_error(
          "over_parent_allocation",
          "A subcategory's amount cannot exceed what its parent's amount leaves after the other subcategories. Raise the parent's amount first, or pass at most max_amount.",
          max_amount: budget_amount(max)
        )
      end

      budget_category.update!(budgeted_spending: amount)
      @record_type = "BudgetCategory"

      {
        id: budget_category.id,
        updated: true,
        budget_category: budget_category_snapshot(budget_category, budget),
        totals: totals(budget)
      }
    end

    def find_expense_category(value)
      category = find_family_category(value)

      if category.nil? && uncategorized_name?(value)
        return [ nil, tool_error("uncategorized_not_settable", "The uncategorized row is the part of the total not given to categories. Change the total or a category amount instead.") ]
      end

      return [ nil, tool_error("category_not_found", "Use a category_id from get_budget or get_categories.", category: value) ] unless category
      return [ nil, tool_error("not_an_expense_category", "Only expense categories have budget amounts.", category: category.name) ] unless category.classification == "expense"

      [ category, nil ]
    end

    def parse_amount(value)
      number = case value
      when Numeric then value.to_d
      when String then BigDecimal(value.strip)
      end

      unless number&.finite? && !number.negative? && number <= MAX_AMOUNT
        return [ nil, tool_error("invalid_amount", "amount must be a number from 0 to #{MAX_AMOUNT}.") ]
      end

      [ number, nil ]
    rescue ArgumentError, TypeError, FloatDomainError
      [ nil, tool_error("invalid_amount", "amount must be a number from 0 to #{MAX_AMOUNT}.") ]
    end

    def budget_snapshot(budget)
      {
        id: budget.id,
        month: budget.to_param,
        start_date: budget.start_date.iso8601,
        end_date: budget.end_date.iso8601,
        budgeted_spending: budget.budgeted_spending && budget_amount(budget.budgeted_spending),
        expected_income: budget.expected_income && budget_amount(budget.expected_income),
        currency: family.currency
      }
    end

    def budget_category_snapshot(budget_category, budget)
      {
        id: budget_category.id,
        budget_id: budget.id,
        month: budget.to_param,
        category_id: budget_category.category_id,
        category_name: budget_category.category.name,
        budgeted_spending: budget_amount(budget_category[:budgeted_spending]),
        currency: family.currency
      }
    end

    # Re-read, so the sums include the write
    def totals(budget)
      budget = Budget.find(budget.id)

      {
        budgeted_spending: budget.budgeted_spending && budget_amount(budget.budgeted_spending),
        allocated_spending: budget_amount(budget.allocated_spending),
        available_to_allocate: budget_amount(budget.available_to_allocate),
        allocation_state: budget.allocation_state.to_s
      }
    end
end
