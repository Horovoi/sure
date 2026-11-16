class BudgetCategoriesController < ApplicationController
  before_action :set_budget

  def index
    @budget_categories = @budget.budget_categories.includes(:category)
    render layout: "wizard"
  end

  def show
    # The drawer shows the carry, so it is brought up to date first
    @budget.recompute_rollover!

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
    movable_before = @budget_category.movable_amount.positive?

    BudgetCategory.transaction do
      unless rollover_enabled_param.nil?
        @budget_category.update!(rollover_enabled: rollover_enabled_param)
        # Later periods opened before this choice had nothing to inherit
        @budget_category.propagate_rollover_choice_forward!
      end

      @budget_category.update_budgeted_spending!(requested) unless requested.nil?
    end

    # After the commit, never inside it: see BudgetCategory.move_allocation!
    @budget.recompute_rollover!
    @budget.budget_categories.reset
    @budget_category.reload

    # The edited row is drawn again when it shows something the user did not type: a
    # parent set below its subcategories is raised to their sum, and the move button
    # comes or goes with the amount it can send away
    adjusted = !requested.nil? && @budget_category[:budgeted_spending] != requested
    @refresh_budget_category_row = adjusted || movable_before != @budget_category.movable_amount.positive?

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget) }
    end
  rescue ActiveRecord::RecordInvalid
    @budget_categories = @budget.budget_categories.includes(:category)
    render :index, status: :unprocessable_entity, layout: "wizard"
  end

  # Moves allocation from one envelope to another of this budget in one step. The
  # rollover recompute runs after move_allocation! has committed (see there).
  def move
    @from = @budget.budget_categories.find(params[:from_id])
    @to = @budget.budget_categories.find(params[:to_id])

    BudgetCategory.move_allocation!(from: @from, to: @to, amount: move_amount_param)
    @budget.recompute_rollover!
    @budget.budget_categories.reset
    @from = @budget.budget_categories.find { |bc| bc.id == @from.id }
    @to = @budget.budget_categories.find { |bc| bc.id == @to.id }

    flash.now[:notice] = t(".success")
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget), notice: t(".success") }
    end
  rescue BudgetCategory::InvalidMove => e
    flash.now[:alert] = e.message
    respond_to do |format|
      format.turbo_stream do
        error = helpers.tag.p(e.message, id: "budget-move-error", class: "text-sm text-destructive", role: "alert", data: { budget_move_target: "error" })
        render turbo_stream: [ turbo_stream.replace("budget-move-error", html: error), *flash_notification_stream_items ], status: :unprocessable_entity
      end
      format.html do
        @budget_categories = @budget.budget_categories.includes(:category)
        render :index, layout: "wizard", status: :unprocessable_entity
      end
    end
  end

  private
    # Budgets live under the Plan page
    def set_breadcrumbs
      @breadcrumbs = plan_breadcrumbs([ t("breadcrumbs.budgets"), nil ])
    end

    def budget_category_params
      @budget_category_params ||= params.expect(budget_category: [ :budgeted_spending, :rollover_enabled ])
    end

    # A blank amount clears the row (a subcategory then shares its parent's amount); nil
    # when the form did not send the field
    def budgeted_spending_param
      return nil unless budget_category_params.key?(:budgeted_spending)

      value = budget_category_params[:budgeted_spending]
      value.presence ? value.to_d : 0.to_d
    end

    # nil when the form did not send the toggle
    def rollover_enabled_param
      return nil unless budget_category_params.key?(:rollover_enabled)

      ActiveModel::Type::Boolean.new.cast(budget_category_params[:rollover_enabled])
    end

    # A blank or non-numeric amount is a zero move, which move_allocation! refuses
    # with "enter an amount greater than zero"
    def move_amount_param
      params.expect(budget_category_move: [ :amount ])[:amount].to_s.to_d
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
