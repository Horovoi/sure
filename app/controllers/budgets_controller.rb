class BudgetsController < ApplicationController
  before_action :set_budget, only: %i[show edit update]

  def index
    redirect_to_current_month_budget
  end

  def show
  end

  def edit
    render layout: "wizard"
  end

  def update
    @budget.update!(budget_params)
    redirect_to budget_budget_categories_path(@budget)
  end

  def picker
    year = (params[:year].presence || Date.current.year).to_i
    render partial: "budgets/picker", locals: { family: Current.family, year: year }
  end

  private

    def budget_create_params
      params.require(:budget).permit(:start_date)
    end

    def budget_params
      params.require(:budget).permit(:budgeted_spending, :expected_income)
    end

    def set_budget
      start_date = Budget.param_to_date(params[:month_year], family: Current.family)
      @budget = Budget.find_or_bootstrap(Current.family, start_date: start_date)
      raise ActiveRecord::RecordNotFound unless @budget

      # Ensure canonical param is used (important for fiscal month mapping)
      canonical = @budget.to_param
      redirect_to(budget_path(@budget)) and return if params[:month_year] != canonical
    end

    def redirect_to_current_month_budget
      current_budget = Budget.find_or_bootstrap(Current.family, start_date: Date.current)
      redirect_to budget_path(current_budget)
    end
end
