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

    # Budgets reach back to the oldest entry (or two years, whichever is earlier) and
    # forward two years, so the coming months can be planned.
    def budget_date_valid?(date, family:)
      start = family.budget_period_start_for(date)
      earliest_start = family.budget_period_start_for(oldest_valid_budget_date(family))
      latest_start = family.budget_period_start_for(Date.current.advance(years: 2))

      start >= earliest_start && start <= latest_start
    end

    # Read-only: the budget whose period contains the date, or nil. Unlike
    # find_or_bootstrap it never creates, moves or syncs a budget, so pages
    # that only show a figure from it can call it on every GET.
    # The start date alone names a budget, so a budget saved with a wrong end date
    # (see budget_starting_on) is still found.
    def find_for_date(family, date)
      family.budgets.find_by(start_date: family.budget_period_start_for(date))
    end

    def find_or_bootstrap(family, start_date:)
      return nil unless budget_date_valid?(start_date, family: family)

      period_start = family.budget_period_start_for(start_date)
      period_end = family.budget_period_end_for(period_start)

      Budget.transaction do
        budget = budget_starting_on(family, period_start, period_end) ||
          adopt_budget_from_other_fiscal_start_day(family, period_start, period_end) ||
          family.budgets.create!(start_date: period_start, end_date: period_end, currency: family.currency)

        budget.sync_budget_categories

        budget
      end
    end

    private
      # The start date alone names a budget (it is unique per family). A budget saved
      # while a fiscal start day past the end of a short month (29 to 31) gave periods
      # a wrong end date gets the right one here.
      def budget_starting_on(family, period_start, period_end)
        budget = family.budgets.find_by(start_date: period_start)
        return nil unless budget

        budget.update(end_date: period_end) unless budget.end_date == period_end
        budget
      end

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
      # This budget, not a copy loaded again, so the row reads the totals loaded here.
      bc.budget = self
      bc.budgeted_spending = [ available_to_allocate, 0 ].max
      bc.currency = family.currency
    end
  end

  # The transactions the budget counts: none from an account excluded from reports (w3-reports)
  def transactions
    family.transactions.visible.merge(Account.included_in_reports).in_period(period)
  end

  def name
    start_date.strftime("%B %Y")
  end

  def initialized?
    budgeted_spending.present?
  end

  # =============================================================================
  # Copy a previous budget
  # =============================================================================

  # The newest set-up budget of the family that starts before this one: what an
  # empty month offers to copy.
  def most_recent_initialized_budget
    family.budgets
      .includes(:budget_categories)
      .where(start_date: ...start_date)
      .where.not(budgeted_spending: nil)
      .order(start_date: :desc)
      .first
  end

  # Copies the total, the expected income and each expense row's amount from an
  # earlier budget of the family. Amounts are written to each row as they are, never
  # added up from subcategories, so a parent and its subcategory keep the source
  # amounts. Rows of categories that are now income stay hidden and untouched. The
  # rollover carry is not copied: the rollover code calculates it.
  def copy_from!(source_budget)
    raise ArgumentError, "source budget must belong to the same family" unless source_budget.family_id == family_id
    raise ArgumentError, "source budget must precede target budget" unless source_budget.start_date < start_date

    Budget.transaction do
      sync_budget_categories

      update!(
        budgeted_spending: source_budget.budgeted_spending,
        expected_income: source_budget.expected_income || 0
      )

      target_by_category = budget_categories.index_by(&:category_id)

      source_budget.budget_categories.each do |source_bc|
        target_bc = target_by_category[source_bc.category_id]
        next unless target_bc

        target_bc.update!(budgeted_spending: source_bc[:budgeted_spending])
      end
    end
  end

  # Income by category, without the refunds of expense categories: those lower the
  # spending of their category instead (see #refunds_in_expense_categories), so
  # counting them here as well would count them twice.
  def income_category_totals
    totals = income_totals.category_totals.select do |ct|
      !ct.category.subcategory? && (ct.category.uncategorized? || (ct.category.persisted? && ct.category.classification == "income"))
    end

    with_weights(totals)
  end

  # Spending by top-level category, net of the category's refunds and never below 0.
  def expense_category_totals
    totals = expense_totals.category_totals.reject { |ct| ct.category.subcategory? }.map do |ct|
      ct.with(total: net_category_spending(ct.category, ct.total))
    end

    with_weights(totals)
  end

  def current?
    start_date == family.budget_period_start_for(Date.current) && end_date == family.budget_period_end_for(start_date)
  end

  # Whole days from today through the period's last day (today counts); 0 once the
  # period is over. Counts to end_date, so a fiscal period that ends in the next
  # calendar month gets its real number of days.
  def days_remaining
    [ (end_date - Date.current).to_i + 1, 0 ].max
  end

  # The setup wizard can be confirmed once the budget has a total and its categories
  # do not add up to more than it. A budget with only a total (nothing allocated) is
  # valid: what it spends shows as uncategorized.
  def confirmable?
    initialized? && !over_allocated?
  end

  # The neighbours are the periods just before the first day and just after the last
  # day. Stepping a month from the start date would skip or repeat a period when the
  # fiscal start day is past the end of a short month (day 31 and February).
  def previous_budget_param
    previous_date = start_date - 1.day
    return nil unless self.class.budget_date_valid?(previous_date, family: family)

    self.class.date_to_param(previous_date, family: family)
  end

  def next_budget_param
    next_date = end_date + 1.day
    return nil unless self.class.budget_date_valid?(next_date, family: family)

    self.class.date_to_param(next_date, family: family)
  end

  def to_donut_segments_json
    unused_segment_id = "unused"

    # Continuous gray segment for a budget without an amount yet. A budget with only a
    # total (nothing allocated) still shows what was spent.
    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless initialized? && !over_allocated?

    segments = donut_budget_categories.map do |bc|
      { color: bc.category.color, amount: budget_category_actual_spending(bc), id: bc.id }
    end

    if available_to_spend.positive?
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  # The rows of the spending donut: top-level categories (a parent's spending already
  # includes its subcategories) plus the uncategorized row when something was spent
  # without a category.
  def donut_budget_categories
    rows = budget_categories.reject(&:subcategory?)
    uncategorized = uncategorized_budget_category
    rows << uncategorized if budget_category_actual_spending(uncategorized).positive?
    rows
  end

  # =============================================================================
  # Actuals: How much user has spent on each budget category
  # =============================================================================
  def estimated_spending
    income_statement.median_expense(interval: "month")
  end

  # Spending net of the refunds in expense categories, never below 0.
  def actual_spending
    [ expense_totals.total - refunds_in_expense_categories, 0 ].max
  end

  # A category's spending net of its refunds, never below 0. A parent's totals
  # include its subcategories, so a subcategory refund lowers both.
  def budget_category_actual_spending(budget_category)
    category = budget_category.category
    expense = expense_totals_by_category[category.totals_key]&.total || 0

    net_category_spending(category, expense)
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

  # Income without the refunds of expense categories, which lower spending instead.
  def actual_income
    income_totals.total - refunds_in_expense_categories
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

  # =============================================================================
  # Subscription reservations (decision 35)
  #
  # Money set aside for the charges of the family's subscriptions and other
  # recurring rows that fall in this period but are not generated yet. It is an
  # additive figure: spent, available and allocation figures do not include it.
  # =============================================================================

  # What one category has reserved, in the family currency, and how many of its
  # rows were left out because their currency has no exchange rate.
  SubscriptionReservation = Data.define(:amount, :unconvertible_count) do
    def self.empty
      new(amount: 0.to_d, unconvertible_count: 0)
    end

    def +(other)
      with(amount: amount + other.amount, unconvertible_count: unconvertible_count + other.unconvertible_count)
    end
  end

  # A charge linked to the row this many days around a reserved date means
  # that date is already paid. The same window as the subscription reconciler's
  # clear match, so a real or generated charge is never also reserved.
  SUBSCRIPTION_RESERVATION_MATCH_DAYS = 5

  # Category id to SubscriptionReservation, loaded once per budget. A past
  # budget reserves nothing.
  def subscription_reservations_by_category_id
    @subscription_reservations_by_category_id ||= build_subscription_reservations
  end

  # The reservations of the categories this budget shows. Each category counts
  # once: a parent's own reservation does not include its subcategories here.
  def subscription_reservation_total
    @subscription_reservation_total ||= begin
      category_ids = budget_categories.map(&:category_id).to_set
      subscription_reservations_by_category_id
        .select { |category_id, _| category_ids.include?(category_id) }
        .values
        .sum(SubscriptionReservation.empty)
    end
  end

  def subscriptions_reserved
    Money.new(subscription_reservation_total.amount, family.currency)
  end

  def subscriptions_reserved_unconvertible_count
    subscription_reservation_total.unconvertible_count
  end

  # Spent and reserved shares of the budgeted amount for the summary bar. The
  # reserved share is capped at what the spent share leaves free.
  def spent_bar_width_percent
    [ percent_of_budget_spent.to_f, 100 ].min
  end

  def subscriptions_reserved_bar_width_percent
    reserved = subscription_reservation_total.amount
    return 0 unless budgeted_spending.to_d.positive? && reserved.positive?

    [ (reserved / budgeted_spending.to_d * 100).to_f, 100 - spent_bar_width_percent ].min.clamp(0, 100)
  end

  private
    def build_subscription_reservations
      return {} if end_date < Date.current

      rows = family.recurring_transactions
        .active
        .user_managed
        .where.not(category_id: nil)
        .where.not(next_expected_date: nil)
        .where(next_expected_date: ..end_date)
        .where("recurring_transactions.amount > 0")
        .to_a
        .select { |row| row.amount_for_transaction.to_d.positive? }
      return {} if rows.empty?

      linked_dates = subscription_linked_charge_dates(rows)
      rates = subscription_reservation_rates(rows)

      rows.each_with_object({}) do |row, result|
        charge_dates = linked_dates.fetch(row.id, [])
        dates = subscription_reservation_dates(row).reject do |date|
          charge_dates.any? { |charge_date| (charge_date - date).abs <= SUBSCRIPTION_RESERVATION_MATCH_DAYS }
        end
        next if dates.empty?

        rate = rates[row.currency]
        reservation = if rate.nil?
          SubscriptionReservation.new(amount: 0.to_d, unconvertible_count: 1)
        else
          SubscriptionReservation.new(amount: row.amount_for_transaction.to_d * dates.size * rate.to_d, unconvertible_count: 0)
        end

        result[row.category_id] = (result[row.category_id] || SubscriptionReservation.empty) + reservation
      end
    end

    # Recurring row id to the dates of its linked charges near this period, in one query
    def subscription_linked_charge_dates(rows)
      window = (start_date - SUBSCRIPTION_RESERVATION_MATCH_DAYS)..(end_date + SUBSCRIPTION_RESERVATION_MATCH_DAYS)

      Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(transactions: { recurring_transaction_id: rows.map(&:id) })
        .where(date: window)
        .pluck("transactions.recurring_transaction_id", "entries.date")
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
    end

    # Rates into the family currency by the nearest-rate rule. A currency with no
    # stored rate at all is absent, never converted at 1.
    def subscription_reservation_rates(rows)
      foreign = rows.map(&:currency).uniq - [ family.currency ]
      rates = foreign.any? ? ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current) : {}
      rates.merge(family.currency => 1)
    end

    # The row's billing dates in this period, from its next expected date on.
    # The dates before next_expected_date are generated (or skipped) already.
    def subscription_reservation_dates(row)
      dates = []
      date = row.next_expected_date

      # Budgets reach two years ahead, so a monthly row steps at most about 25 times
      400.times do
        break if date > end_date

        dates << date if date >= start_date
        following = row.calculate_next_expected_date(date)
        break unless following > date

        date = following
      end

      dates
    end


    def income_statement
      @income_statement ||= family.income_statement
    end

    def expense_totals
      @expense_totals ||= income_statement.expense_totals(period: period)
    end

    def income_totals
      @income_totals ||= income_statement.income_totals(period: period)
    end

    # =============================================================================
    # Refund netting
    #
    # The income statement classifies each transaction by the sign of its amount, so
    # a refund in an expense category (an inflow) lands in the income totals under
    # that category. Budgets net it against the category's spending. Inflows without
    # a category stay gross: one is as likely to be income as a refund.
    # =============================================================================

    # Refunds of the budget's top-level expense categories. A parent's total includes
    # its subcategories, so counting top-level rows only counts each refund once.
    def refunds_in_expense_categories
      @refunds_in_expense_categories ||= refund_netted_category_ids.sum do |category_id|
        income_totals_by_category[category_id]&.total || 0
      end
    end

    def refund_netted_category_ids
      @refund_netted_category_ids ||= budget_categories.reject(&:subcategory?).map(&:category_id).to_set
    end

    # Spending of one category less its refunds, never below 0. Only persisted expense
    # categories net their refunds; the uncategorized row stays gross.
    def net_category_spending(category, expense)
      return expense unless category.persisted? && category.classification == "expense"

      refund = income_totals_by_category[category.totals_key]&.total || 0
      [ expense - refund, 0 ].max
    end

    def expense_totals_by_category
      @expense_totals_by_category ||= expense_totals.category_totals.index_by { |ct| ct.category.totals_key }
    end

    def income_totals_by_category
      @income_totals_by_category ||= income_totals.category_totals.index_by { |ct| ct.category.totals_key }
    end

    # Drops zero rows and weighs each row against the rows shown, largest first, so
    # the bars of the actuals summary add up to 100%.
    def with_weights(category_totals)
      shown = category_totals.reject { |ct| ct.total.zero? }
      sum = shown.sum(&:total)

      shown.map { |ct| ct.with(weight: sum.zero? ? 0 : ct.total.to_f / sum * 100) }.sort_by(&:weight).reverse
    end
end
