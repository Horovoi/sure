class BudgetCategoriesController < ApplicationController
  before_action :set_budget

  def index
    @budget_categories = @budget.budget_categories.includes(:category)
    render layout: "wizard"
  end

  def show
    # The budget totals (IncomeStatement) leave out these kinds, so the drilldown does
    # too: a matched transfer must not show under a category it does not count in.
    @recent_transactions = @budget.transactions
                                  .where.not(transactions: { kind: Transaction::BUDGET_EXCLUDED_KINDS })

    if params[:id] == BudgetCategory.uncategorized.id
      @budget_category = @budget.uncategorized_budget_category
      @recent_transactions = @recent_transactions.where(transactions: { category_id: nil })
    else
      @budget_category = @budget.budget_categories.find(params[:id])
      @recent_transactions = @recent_transactions.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
                                                 .where("categories.id = ? OR categories.parent_id = ?", @budget_category.category.id, @budget_category.category.id)
    end

    @recent_transactions = @recent_transactions.order("entries.date DESC, ABS(entries.amount) DESC").take(3)
  end

  # A subcategory's change also changes its parent (BudgetCategory#update_budgeted_spending!),
  # so the stream re-renders the parent's row with it.
  def update
    @budget_category = @budget.budget_categories.find(params[:id])
    requested = budgeted_spending_param
    @budget_category.update_budgeted_spending!(requested)
    @budget.budget_categories.reset

    # A parent set below its subcategories is raised to their sum: show the stored amount
    @budget_category_adjusted = @budget_category[:budgeted_spending] != requested

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget) }
    end
  rescue ActiveRecord::RecordInvalid
    @budget_categories = @budget.budget_categories.includes(:category)
    render :index, status: :unprocessable_entity, layout: "wizard"
  end

  private
    # A blank amount clears the row (a subcategory then shares its parent's amount)
    def budgeted_spending_param
      value = params.expect(budget_category: [ :budgeted_spending ])[:budgeted_spending]
      value.presence ? value.to_d : 0.to_d
    end

    # The Categories step needs a set-up budget. A month outside the budget range is a
    # 404; a month whose Setup step is not done goes to that step first.
    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Budget.find_or_bootstrap(Current.family, start_date: start_date)
      raise ActiveRecord::RecordNotFound unless @budget

      if params[:budget_month_year] != @budget.to_param
        redirect_to budget_budget_categories_path(@budget) and return
      end

      redirect_to edit_budget_path(@budget) unless action_name == "show" || @budget.initialized?
    end
end
