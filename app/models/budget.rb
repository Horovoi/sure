class Budget < ApplicationRecord
  include Monetizable

  PARAM_DATE_FORMAT = "%b-%Y"

  belongs_to :family

  # Every budget category row, whatever its category's classification. Only used to
  # sync rows and to destroy them with the budget.
  has_many :all_budget_categories, class_name: "BudgetCategory", dependent: :destroy

  # The rows a budget shows and counts: those whose category is an expense. A category
  # switched to income keeps its row (and amount), hidden, so switching it back restores it.
  has_many :budget_categories, -> { includes(:category).where(category_id: Category.expenses.select(:id)) }

  validates :start_date, :end_date, presence: true
  validates :start_date, :end_date, uniqueness: { scope: :family_id }

  monetize :budgeted_spending, :expected_income, :allocated_spending,
           :actual_spending, :available_to_spend, :available_to_allocate,
           :estimated_spending, :estimated_income, :actual_income, :remaining_expected_income

  class << self
    def date_to_param(date, family: nil)
      start_for_param = family ? family.budget_period_start_for(date) : date
      start_for_param.strftime(PARAM_DATE_FORMAT).downcase
    end

    def param_to_date(param, family: nil)
      parsed = Date.strptime(param, PARAM_DATE_FORMAT)
      return parsed.beginning_of_month unless family

      # Interpret the param as the month that STARTS the budget period
      # Example: "Mar-2025" -> Mar 10, 2025 (if fiscal_start_day = 10)
      day = family.fiscal_start_day
      last_dom = Date.new(parsed.year, parsed.month, -1).day
      Date.new(parsed.year, parsed.month, [ day, last_dom ].min)
    end

    def budget_date_valid?(date, family:)
      start = family.budget_period_start_for(date)
      earliest_start = family.budget_period_start_for(oldest_valid_budget_date(family))
      current_start = family.budget_period_start_for(Date.current)

      start >= earliest_start && start <= current_start
    end

    # Read-only: the budget whose period contains the date, or nil. Unlike
    # find_or_bootstrap it never creates, moves or syncs a budget, so pages
    # that only show a figure from it can call it on every GET.
    def find_for_date(family, date)
      period_start = family.budget_period_start_for(date)
      family.budgets.find_by(start_date: period_start, end_date: family.budget_period_end_for(period_start))
    end

    def find_or_bootstrap(family, start_date:)
      return nil unless budget_date_valid?(start_date, family: family)

      period_start = family.budget_period_start_for(start_date)
      period_end = family.budget_period_end_for(period_start)

      Budget.transaction do
        budget = family.budgets.find_by(start_date: period_start, end_date: period_end) ||
          adopt_budget_from_other_fiscal_start_day(family, period_start, period_end) ||
          Budget.find_or_create_by!(family: family, start_date: period_start, end_date: period_end) do |b|
            b.currency = family.currency
          end

        budget.sync_budget_categories

        budget
      end
    end

    private
      # A budget's period comes from the family's fiscal start day. After that day changes,
      # the budget for a month (say Mar 1 - Mar 31) no longer matches the month's new
      # period (Mar 10 - Apr 9). Move it to the new period instead of starting an empty
      # budget, so its amounts stay reachable. Skipped when another budget already
      # uses one of the new dates.
      def adopt_budget_from_other_fiscal_start_day(family, period_start, period_end)
        month = period_start.beginning_of_month..period_start.end_of_month
        stranded = family.budgets.where(start_date: month).where.not(start_date: period_start).order(:start_date).first
        return nil unless stranded

        stranded.update(start_date: period_start, end_date: period_end) ? stranded : nil
      end

      def oldest_valid_budget_date(family)
        # Allow going back to either the earliest entry date OR 2 years ago, whichever is earlier
        # Ensure we return Dates (not TimeWithZone) to avoid type errors in month arithmetic
        two_years_ago = 2.years.ago.to_date.beginning_of_month
        oldest_entry_date = family.oldest_entry_date.beginning_of_month
        [ two_years_ago, oldest_entry_date ].min
      end
  end

  def period
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def to_param
    self.class.date_to_param(start_date, family: family)
  end

  # Adds a row for each expense category that has none. Never removes rows: this runs on
  # every page view, and rows of categories that are no longer expenses are hidden by
  # `budget_categories` instead (deleted categories cascade on their own).
  def sync_budget_categories
    current_category_ids = family.categories.expenses.pluck(:id).to_set
    existing_budget_category_ids = all_budget_categories.pluck(:category_id).to_set
    categories_to_add = current_category_ids - existing_budget_category_ids

    categories_to_add.each do |category_id|
      all_budget_categories.create!(
        category_id: category_id,
        budgeted_spending: 0,
        currency: family.currency
      )
    end

    budget_categories.reset if categories_to_add.any?
  end

  def uncategorized_budget_category
    budget_categories.uncategorized.tap do |bc|
      bc.budgeted_spending = [ available_to_allocate, 0 ].max
      bc.currency = family.currency
    end
  end

  def transactions
    family.transactions.visible.in_period(period)
  end

  def name
    start_date.strftime("%B %Y")
  end

  def initialized?
    budgeted_spending.present?
  end

  def income_category_totals
    income_totals.category_totals.reject { |ct| ct.category.subcategory? || ct.total.zero? }.sort_by(&:weight).reverse
  end

  def expense_category_totals
    expense_totals.category_totals.reject { |ct| ct.category.subcategory? || ct.total.zero? }.sort_by(&:weight).reverse
  end

  def current?
    start_date == family.budget_period_start_for(Date.today) && end_date == family.budget_period_end_for(start_date)
  end

  def previous_budget_param
    previous_date = start_date - 1.month
    return nil unless self.class.budget_date_valid?(previous_date, family: family)

    self.class.date_to_param(previous_date, family: family)
  end

  def next_budget_param
    return nil if current?

    next_date = start_date + 1.month
    return nil unless self.class.budget_date_valid?(next_date, family: family)

    self.class.date_to_param(next_date, family: family)
  end

  def to_donut_segments_json
    unused_segment_id = "unused"

    # Continuous gray segment for empty budgets
    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless allocations_valid?

    segments = budget_categories.map do |bc|
      { color: bc.category.color, amount: budget_category_actual_spending(bc), id: bc.id }
    end

    if available_to_spend.positive?
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  # =============================================================================
  # Actuals: How much user has spent on each budget category
  # =============================================================================
  def estimated_spending
    income_statement.median_expense(interval: "month")
  end

  def actual_spending
    expense_totals.total
  end

  def budget_category_actual_spending(budget_category)
    expense_totals.category_totals.find { |ct| ct.category.id == budget_category.category.id }&.total || 0
  end

  def category_median_monthly_expense(category)
    income_statement.median_expense(category: category, exclude_current_period: true)
  end

  def category_avg_monthly_expense(category)
    income_statement.avg_expense(category: category, exclude_current_period: true)
  end

  def available_to_spend
    (budgeted_spending || 0) - actual_spending
  end

  def percent_of_budget_spent
    return 0 unless budgeted_spending.to_d > 0

    (actual_spending / budgeted_spending.to_f) * 100
  end

  def overage_percent
    return 0 unless available_to_spend.negative?

    available_to_spend.abs / actual_spending.to_f * 100
  end

  # =============================================================================
  # Budget allocations: How much user has budgeted for all parent categories combined
  # =============================================================================
  def allocated_spending
    budget_categories.reject { |bc| bc.subcategory? }.sum(&:budgeted_spending)
  end

  def allocated_percent
    return 0 unless budgeted_spending && budgeted_spending > 0

    (allocated_spending / budgeted_spending.to_f) * 100
  end

  def available_to_allocate
    (budgeted_spending || 0) - allocated_spending
  end

  # The one definition of where a budget stands, used by the budget page and the setup
  # wizard alike:
  #   :not_set_up      - no spending amount yet (the Setup step is not done)
  #   :unallocated     - set up, nothing given to categories
  #   :under_allocated - some, but not all, of the amount given to categories
  #   :fully_allocated - all of it given to categories
  #   :over_allocated  - categories add up to more than the amount
  def allocation_state
    return :not_set_up unless initialized?
    return :over_allocated if available_to_allocate.negative?
    return :unallocated unless allocated_spending.positive?

    available_to_allocate.zero? ? :fully_allocated : :under_allocated
  end

  def over_allocated?
    allocation_state == :over_allocated
  end

  # The Categories step is complete: something is allocated and nothing over-allocated.
  def allocations_valid?
    allocation_state.in?(%i[under_allocated fully_allocated])
  end

  # =============================================================================
  # Income: How much user earned relative to what they expected to earn
  # =============================================================================
  def estimated_income
    family.income_statement.median_income(interval: "month")
  end

  def actual_income
    family.income_statement.income_totals(period: self.period).total
  end

  def actual_income_percent
    return 0 unless expected_income.to_d > 0

    (actual_income / expected_income.to_f) * 100
  end

  def remaining_expected_income
    expected_income.to_d - actual_income
  end

  def surplus_percent
    return 0 unless remaining_expected_income.negative? && expected_income.to_d > 0

    remaining_expected_income.abs / expected_income.to_f * 100
  end

  private
    def income_statement
      @income_statement ||= family.income_statement
    end

    def expense_totals
      @expense_totals ||= income_statement.expense_totals(period: period)
    end

    def income_totals
      @income_totals ||= family.income_statement.income_totals(period: period)
    end
end
