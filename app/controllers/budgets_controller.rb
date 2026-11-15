class BudgetsController < ApplicationController
  before_action :set_budget, only: %i[show edit update copy_previous]

  def index
    redirect_to_current_month_budget
  end

  def show
    @source_budget = @budget.most_recent_initialized_budget unless @budget.initialized?
  end

  def edit
    render layout: "wizard"
  end

  def update
    @budget.update!(budget_params)
    redirect_to budget_budget_categories_path(@budget)
  end

  # Fills an empty month with the amounts of the newest earlier budget, then opens the
  # categories step so they can be reviewed. Refuses a budget that is already set up.
  def copy_previous
    if @budget.initialized?
      redirect_to budget_path(@budget), alert: t(".already_initialized")
      return
    end

    source_budget = @budget.most_recent_initialized_budget

    if source_budget
      @budget.copy_from!(source_budget)
      redirect_to budget_budget_categories_path(@budget), notice: t(".success", source_name: source_budget.name)
    else
      redirect_to budget_path(@budget), alert: t(".no_source")
    end
  end

  def picker
    year = (params[:year].presence || Date.current.year).to_i
    render partial: "budgets/picker", locals: { family: Current.family, year: year }
  end

  private

    def budget_create_params
      params.expect(budget: [ :start_date ])
    end

    # A blank expected income means none expected. Left nil, it would break the income
    # summary on the budget page.
    def budget_params
      params.expect(budget: [ :budgeted_spending, :expected_income ]).tap do |permitted|
        permitted[:expected_income] = permitted[:expected_income].presence || 0 if permitted.key?(:expected_income)
      end
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
