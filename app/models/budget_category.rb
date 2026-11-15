class BudgetCategory < ApplicationRecord
  include Monetizable

  belongs_to :budget
  belongs_to :category

  validates :budget_id, uniqueness: { scope: :category_id }
  validates :budgeted_spending, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  monetize :budgeted_spending, :available_to_spend, :avg_monthly_expense, :median_monthly_expense, :actual_spending,
           :rolled_over_amount

  class Group
    attr_reader :budget_category, :budget_subcategories

    delegate :category, to: :budget_category
    delegate :name, :color, to: :category

    def self.for(budget_categories)
      top_level_categories = budget_categories.select { |budget_category| budget_category.category.parent_id.nil? }
      top_level_categories.map do |top_level_category|
        subcategories = budget_categories.select { |bc| bc.category.parent_id == top_level_category.category_id && top_level_category.category_id.present? }
        new(top_level_category, subcategories.sort_by { |subcategory| subcategory.category.name })
      end.sort_by { |group| group.category.name }
    end

    # all_subcategories: every subcategory of the parent, when budget_subcategories is a
    # filtered subset (the budget page's Over budget / On track sections).
    def initialize(budget_category, budget_subcategories = [], all_subcategories: budget_subcategories)
      @budget_category = budget_category
      @budget_subcategories = budget_subcategories
      @all_subcategories = all_subcategories
    end

    # Parent spending that no subcategory accounts for, shown as an "Other <parent>" row.
    def other_spending
      return 0 unless @all_subcategories.any?
      direct = budget_category.actual_spending - @all_subcategories.sum(&:actual_spending)
      [ direct, 0 ].max
    end
  end

  # Raised by move_allocation! for a move the budget cannot represent. Carries an i18n
  # key, so the controller shows the reason in the UI language.
  class InvalidMove < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(I18n.t("budget_categories.move.errors.#{reason}"))
    end
  end

  class << self
    def uncategorized
      new(
        id: Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "uncategorized"),
        category: nil,
      )
    end

    # Moves an amount of allocation from one envelope to another of the same budget in
    # one transaction (upstream 3d6a8d8b6). Both sides change through
    # update_budgeted_spending!, so parents stay the sum of their subcategories plus
    # their reserve. No history is kept: only the resulting amounts.
    #
    # The caller recomputes the rollover chain after this returns, never inside it: the
    # calculator takes an advisory lock, and taking it while these row locks are held
    # would invert the order every other caller uses and could deadlock two moves.
    def move_allocation!(from:, to:, amount:)
      amount = amount.to_d
      validate_move!(from: from, to: to, amount: amount)

      transaction do
        # update_budgeted_spending! locks its row and, for a subcategory, the parent.
        # Two moves in opposite directions would each hold what the other wants, so
        # every row this touches is locked first, by ascending id.
        where(id: lock_ids_for_move(from, to)).order(:id).lock.to_a

        from.reload
        to.reload

        # Checked again under the lock: the amount read before it may be stale
        raise InvalidMove.new(:insufficient_funds) if amount > from.movable_amount

        from.update_budgeted_spending!((from[:budgeted_spending] || 0) - amount)
        to.update_budgeted_spending!((to[:budgeted_spending] || 0) + amount)
      end

      [ from.reload, to.reload ]
    end

    private
      def validate_move!(from:, to:, amount:)
        raise InvalidMove.new(:non_positive_amount) unless amount.positive?
        # Before the budget check: the synthetic uncategorized row has no budget row
        raise InvalidMove.new(:uncategorized) if [ from, to ].any? { |bc| bc[:category_id].nil? || !bc.persisted? }
        raise InvalidMove.new(:different_budgets) unless from.budget_id == to.budget_id
        raise InvalidMove.new(:same_category) if from.id == to.id
        raise InvalidMove.new(:parent_child) if direct_lineage?(from, to)
        raise InvalidMove.new(:insufficient_funds) if amount > from.movable_amount
      end

      # A parent is rebuilt from its subcategories plus its reserve, so money moved
      # between a parent and its own subcategory would be derived away again. Refused.
      def direct_lineage?(from, to)
        from[:category_id] == to.category.parent_id || to[:category_id] == from.category.parent_id
      end

      # from, to, and the parents update_budgeted_spending! will touch
      def lock_ids_for_move(from, to)
        parent_category_ids = [ from, to ].filter_map { |bc| bc.category.parent_id }
        parent_ids = parent_category_ids.any? ? where(budget_id: from.budget_id, category_id: parent_category_ids).pluck(:id) : []

        ([ from.id, to.id ] + parent_ids).uniq
      end
  end

  def initialized?
    budget.initialized?
  end

  def category
    super || budget.family.categories.uncategorized
  end

  def name
    category.name
  end

  def actual_spending
    budget.budget_category_actual_spending(self)
  end

  # Sets this row's amount, the one way the Categories step and the update_budget
  # tool change a category (Budget#copy_from! writes the rows as they are instead).
  #
  # Parents are bottom-up: a subcategory's change goes to its parent too, so a
  # subcategory never has to fit inside what its parent leaves. The parent keeps
  # any amount set on it beyond its subcategories (its reserve), and is never
  # below the sum of its subcategories; an amount set on a parent below that sum
  # is raised to it.
  def update_budgeted_spending!(new_budgeted_spending)
    new_amount = new_budgeted_spending.presence&.to_d || 0.to_d

    self.class.transaction do
      lock!
      previous_budgeted_spending = self[:budgeted_spending] || 0

      if subcategory?
        update!(budgeted_spending: new_amount)
        sync_parent_budgeted_spending!(previous_budgeted_spending: previous_budgeted_spending)
      elsif new_amount.negative?
        # Not raised to the subcategories' sum: a negative amount is refused by the
        # validation, as it is for a subcategory
        update!(budgeted_spending: new_amount)
      else
        update!(budgeted_spending: [ new_amount, subcategories_budgeted_total ].max)
      end
    end

    # The budget's loaded rows and the memoized parent hold the amounts from before
    budget.budget_categories.reset
    @parent_budget_category = nil
    self
  end

  # =============================================================================
  # Rollover (w3-envelope, see Budget::RolloverCalculator)
  # =============================================================================

  # Stored by Budget::RolloverCalculator, never derived on read. Read through the toggle
  # (and 0 for a subcategory sharing its parent's amount), so a stale amount left by a
  # toggle switched off never counts.
  def rolled_over_amount
    return 0 unless rollover_enabled?
    return 0 if inherits_parent_budget?

    super || 0
  end

  def rolled_over?
    display_rolled_over_amount.positive?
  end

  # The carry a card shows: a shared subcategory shows its parent's, a parent adds the
  # carry of its ring-fenced subcategories (the parent's own carry is net of theirs), so
  # its budget, carry, spending and amount left reconcile.
  def display_rolled_over_amount
    return parent_budget_category&.rolled_over_amount || 0 if inherits_parent_budget?
    return rolled_over_amount if subcategory?

    rolled_over_amount + ring_fenced_subcategories_rollover
  end

  def display_rolled_over_amount_money
    Money.new(display_rolled_over_amount, budget.currency)
  end

  # Rollover is a standing choice about the envelope: the later periods that exist
  # already take the choice just made. Periods created later inherit it from the last
  # set-up budget (Budget#inherited_rollover_flags).
  def propagate_rollover_choice_forward!
    BudgetCategory
      .joins(:budget)
      .where(category_id: category_id)
      .where(budgets: { family_id: budget.family_id })
      .where("budgets.start_date > ?", budget.start_date)
      .where.not(rollover_enabled: rollover_enabled)
      .update_all(rollover_enabled: rollover_enabled, updated_at: Time.current)
  end

  # What a move can send away from this row. A subcategory, its whole amount. A parent,
  # only its reserve: its amount already holds its subcategories' amounts, and moving
  # those would leave it below their sum (the next subcategory edit would put the money
  # back).
  def movable_amount
    gross = self[:budgeted_spending] || 0
    return gross if subcategory?

    [ gross - subcategories.sum { |child| child[:budgeted_spending] || 0 }, 0 ].max
  end

  def movable_amount_money
    Money.new(movable_amount, budget.currency)
  end

  def avg_monthly_expense
    budget.category_avg_monthly_expense(category)
  end

  def median_monthly_expense
    budget.category_median_monthly_expense(category)
  end

  def subcategory?
    category.parent_id.present?
  end

  # Returns true if this subcategory has no individual budget limit and should use parent's budget
  def inherits_parent_budget?
    subcategory? && (self[:budgeted_spending].nil? || self[:budgeted_spending] == 0)
  end

  # Returns the budgeted spending to display in UI
  # For inheriting subcategories, returns the parent's budget for reference
  def display_budgeted_spending
    if inherits_parent_budget?
      parent = parent_budget_category
      return 0 unless parent
      parent[:budgeted_spending] || 0
    else
      self[:budgeted_spending] || 0
    end
  end

  # Returns the parent budget category if this is a subcategory
  def parent_budget_category
    return nil unless subcategory?
    @parent_budget_category ||= budget.budget_categories.find { |bc| bc.category.id == category.parent_id }
  end

  # What is left to spend, so a card reads budget minus spending.
  #
  # A parent's stored amount already holds its subcategories' amounts (see
  # #update_budgeted_spending!) and its spending holds theirs, so the parent is
  # simply its amount less its total spending. A subcategory with its own amount
  # has its own envelope. A subcategory that shares the parent's amount can use
  # what the ring-fenced siblings leave of it, less what the parent and the
  # sharing subcategories spent from that pool; it is over budget by no more than
  # it spent itself, so a shared subcategory with no spending is never marked
  # over because its parent or a sibling overspent.
  def available_to_spend
    if inherits_parent_budget?
      parent = parent_budget_category
      return 0 unless parent

      [ parent.shared_pool_budget - parent.shared_pool_spending, -actual_spending ].max
    elsif subcategory?
      (self[:budgeted_spending] || 0) + rolled_over_amount - actual_spending
    else
      # The ring-fenced subcategories' amounts are in the parent's, their carry is not
      (self[:budgeted_spending] || 0) + rolled_over_amount + ring_fenced_subcategories_rollover - actual_spending
    end
  end

  def percent_of_budget_spent
    if inherits_parent_budget?
      # A shared subcategory's spending against the part of the parent's amount it can use
      parent = parent_budget_category
      return 0 unless parent

      shared_budget = [ parent.shared_pool_budget, 0 ].max
      return 0 if shared_budget == 0 && actual_spending == 0
      return 100 if shared_budget == 0 && actual_spending > 0
      (actual_spending.to_f / shared_budget) * 100
    else
      # Everything there is to spend, the carry included: a category funded only by
      # its carry has money to spend
      budget_amount = (self[:budgeted_spending] || 0) + display_rolled_over_amount
      return 0 if budget_amount == 0 && actual_spending == 0
      return 0 if budget_amount > 0 && actual_spending == 0
      return 100 if budget_amount == 0 && actual_spending > 0
      (actual_spending.to_f / budget_amount) * 100 if budget_amount > 0 && actual_spending > 0
    end
  end

  # The part of a parent's amount that its sharing subcategories (and the parent's
  # own transactions) spend from: the amount and its own carry, less the ring-fenced
  # subcategories' amounts.
  def shared_pool_budget
    (self[:budgeted_spending] || 0) + rolled_over_amount - ring_fenced_subcategories.sum { |child| child[:budgeted_spending] || 0 }
  end

  # A parent's spending that does not come from a ring-fenced subcategory.
  def shared_pool_spending
    actual_spending - ring_fenced_subcategories.sum(&:actual_spending)
  end

  def ring_fenced_subcategories
    subcategories.reject(&:inherits_parent_budget?)
  end

  def ring_fenced_subcategories_rollover
    ring_fenced_subcategories.sum(&:rolled_over_amount)
  end

  def bar_width_percent
    [ percent_of_budget_spent, 100 ].min
  end

  def over_budget?
    available_to_spend.negative?
  end

  # =============================================================================
  # Budget page filter (All / Over budget / On track)
  # =============================================================================

  # Counts the carry too: a category funded only by its carry is budgeted, not
  # unbudgeted spending.
  def budgeted?
    (display_budgeted_spending.to_d + display_rolled_over_amount.to_d).positive?
  end

  def unbudgeted_with_spending?
    !budgeted? && actual_spending.to_d.positive?
  end

  def over_budget_with_budget?
    budgeted? && over_budget?
  end

  # Near-limit rows are still on track: they have money left.
  def on_track?
    budgeted? && !over_budget?
  end

  # Spending with no budget counts as over budget.
  def any_over_budget?
    unbudgeted_with_spending? || over_budget_with_budget?
  end

  def visible_on_track?
    return false unless on_track?

    # Subcategories that share the parent's budget are hidden until they have spending.
    return true unless subcategory? && inherits_parent_budget?

    actual_spending.to_d.positive?
  end

  def near_limit?
    !over_budget? && percent_of_budget_spent >= 90
  end

  # Returns hash with suggested daily spending info or nil if not applicable
  def suggested_daily_spending
    return nil unless available_to_spend > 0
    # The period that contains today, which with fiscal months can span two calendar months.
    return nil unless budget.current?

    days_remaining = budget.days_remaining
    return nil unless days_remaining > 0

    {
      amount: Money.new((available_to_spend / days_remaining), budget.family.currency),
      days_remaining: days_remaining
    }
  end

  def to_donut_segments_json
    unused_segment_id = "unused"
    overage_segment_id = "overage"

    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless actual_spending > 0

    segments = [ { color: category.color, amount: actual_spending, id: id } ]

    if available_to_spend.negative?
      segments.push({ color: "var(--color-destructive)", amount: available_to_spend.abs, id: overage_segment_id })
    else
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  def siblings
    budget.budget_categories.select { |bc| bc.category.parent_id == category.parent_id && bc.id != id }
  end

  # =============================================================================
  # Subscription reservations (see Budget#subscription_reservations_by_category_id)
  # =============================================================================

  # Money set aside for subscription charges of this category in the period that
  # are not generated yet, in the family currency. A parent sums its subcategories.
  def subscriptions_reserved
    Money.new(subscription_reservation.amount, budget.family.currency)
  end

  # Rows of this category (and its subcategories) left out of the figure because
  # their currency has no exchange rate.
  def subscriptions_reserved_unconvertible_count
    subscription_reservation.unconvertible_count
  end

  def subscriptions_reserved?
    subscription_reservation.amount.positive? || subscription_reservation.unconvertible_count.positive?
  end

  # Width of the hatched segment after the spent bar: the reserved share of the
  # budget, capped at what the spent bar leaves free.
  def subscriptions_reserved_bar_width_percent
    budget_amount = display_budgeted_spending.to_d
    reserved = subscription_reservation.amount
    return 0 unless budget_amount.positive? && reserved.positive?

    [ (reserved / budget_amount * 100).to_f, 100 - bar_width_percent.to_f ].min.clamp(0, 100)
  end

  # Read from the budget's loaded categories (like `siblings` and `parent_budget_category`),
  # so a page of budget categories does not run one query per parent category.
  def subcategories
    return [] unless category.parent_id.nil?
    # The synthetic uncategorized row has no id, and every top-level row would match it.
    return [] if category.id.nil?

    budget.budget_categories.select { |bc| bc.category.parent_id == category.id }
  end

  private
    # The rows of a parent's subcategories in this budget, read from the database
    def subcategory_rows_of(parent_category_id)
      BudgetCategory.where(budget_id: budget_id, category_id: Category.where(parent_id: parent_category_id).select(:id))
    end

    def subcategories_budgeted_total
      return 0 if category_id.nil?

      subcategory_rows_of(category_id).sum(:budgeted_spending)
    end

    # The parent becomes the subcategories' sum plus its reserve: the amount it had
    # beyond them before this change. A negative reserve (a parent that was below
    # its subcategories) is not carried, so the parent ends at least at their sum.
    def sync_parent_budgeted_spending!(previous_budgeted_spending:)
      parent = BudgetCategory.where(budget_id: budget_id, category_id: category.parent_id).lock.first
      return unless parent

      siblings_total = subcategory_rows_of(category.parent_id).where.not(id: id).sum(:budgeted_spending)
      reserve = [ (parent[:budgeted_spending] || 0) - siblings_total - previous_budgeted_spending, 0 ].max

      parent.update!(budgeted_spending: siblings_total + (self[:budgeted_spending] || 0) + reserve)
    end

    def subscription_reservation
      @subscription_reservation ||= begin
        reservations = budget.subscription_reservations_by_category_id
        category_ids = [ category.id, *subcategories.map(&:category_id) ].compact

        category_ids.sum(Budget::SubscriptionReservation.empty) do |category_id|
          reservations[category_id] || Budget::SubscriptionReservation.empty
        end
      end
    end
end
