# A savings goal: a target, the accounts that fund it, and the progress their balances
# make toward it. Ported from upstream Sure (savings-goals): earmarks with a shared
# pool, one-off goals and maintained reserves, months-of-expenses targets and
# multi-currency funding. Pledges (goal-pledges) and spending from a goal
# (goal-spending) have their own sections below.
class Goal < ApplicationRecord
  include AASM, Monetizable

  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  # States in which a goal has let go of its money: the shared pool leaves it out, so
  # its links reserve nothing and the account is free again. `paused` is not here:
  # pausing stops feeding a goal, it does not release it.
  #
  # Four places read this and must agree, or free_to_earmark contradicts the pool:
  # Goal.pooled_allocations_for, Account#goal_earmarked_total,
  # GoalAccount#whole_account_link_must_be_exclusive (through #whole_account_conflicts_on)
  # and #restore_must_not_recreate_whole_account_conflict.
  RELEASED_STATES = %w[archived completed].freeze

  # Account types that can back a goal (see #linked_accounts_must_be_fundable)
  FUNDABLE_ACCOUNT_TYPES = %w[Depository Investment Crypto].freeze

  # one_off: reached once and then closed. maintained: a floor to hold, like an
  # emergency fund; it is never completed and has no target date.
  KINDS = %w[one_off maintained].freeze

  # fixed: the typed target. months_of_expenses: target_months times the family's
  # median monthly spend, rewritten each fiscal month by RefreshMaintainedGoalTargetsJob.
  # target_amount stays the single source of truth, so every aggregate keeps reading it.
  TARGET_MODES = %w[fixed months_of_expenses].freeze

  # Display order for active goals: what needs money first (a goal off pace, or a
  # reserve below its floor), then on track, then open-ended, then whole reserves.
  # Paused goals sort after all of these.
  ACTIVE_DISPLAY_STATUS_RANK = { behind: 0, depleted: 0, on_track: 1, no_target_date: 2, funded: 3 }.freeze
  PAUSED_DISPLAY_RANK = 5

  # The trailing window #pace reads, in days
  PACE_WINDOW_DAYS = 90

  # Raised by #consume!. The reason names the rule that refused, so the controller can
  # say which one (goals.consume.errors.<reason>): every one is something the user can act on.
  class ConsumptionRefused < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("goal consumption refused: #{reason}")
    end
  end

  belongs_to :family
  # autosave, so an earmark edit on an already linked account is saved with the goal
  has_many :goal_accounts, dependent: :destroy, autosave: true
  has_many :linked_accounts, through: :goal_accounts, source: :account
  # Pledges (goal-pledges): "I just put X in for this goal", kept when the money arrives
  has_many :goal_pledges, dependent: :destroy
  has_many :open_pledges, -> { pending }, class_name: "GoalPledge", inverse_of: :goal

  monetize :target_amount

  # A blank picker value means "none", not an invalid colour or icon
  normalizes :icon, :color, with: ->(value) { value.presence }

  validates :name, presence: true, length: { maximum: 255 }
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :icon, inclusion: { in: ICONS, allow_nil: true }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true
  validates :kind, inclusion: { in: KINDS }
  validates :target_mode, inclusion: { in: TARGET_MODES }
  validates :target_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_fundable
  validate :linked_accounts_must_belong_to_family
  validate :currency_locked_once_linked
  validate :restore_must_not_recreate_whole_account_conflict
  validate :kind_locked_while_released
  validate :kind_locked_once_consumed
  validate :target_must_cover_what_was_consumed
  validate :months_target_requires_a_reserve

  # before_save, not before_validation: the basis flips only when the goal is saved
  before_save :default_progress_basis_for_market_accounts

  # A months-based target is derived, so it is filled before the presence and
  # positivity checks run. Only on create and when its inputs change: the job owns
  # the monthly cadence, and renaming a goal must not move a financial figure.
  before_validation :apply_months_of_expenses_target,
                    if: -> {
                      months_of_expenses_target? && (
                        new_record? || target_months_changed? || target_mode_changed? || target_amount_changed?
                      )
                    }

  # A reserve has no deadline. The form hides the field, so a date can only come from
  # a kind change or a crafted request: cleared rather than refused.
  before_validation :clear_target_date_for_maintained

  # Completing freezes the balance, so a missing rate must refuse the write rather than
  # freeze a partial subtotal
  before_validation :prepare_completion_conversion, if: -> { state_changed? && completed? }

  # Autosave validates each link on its own, each taking its account lock in turn. Taking
  # the whole set here, sorted, keeps the lock order the same for every request.
  before_validation :lock_whole_account_claims_in_order

  # Side effects hang off the persisted state change, inside the save transaction, so
  # the non-bang `goal.complete` (which does not save) never stamps a snapshot
  after_save :apply_state_change_side_effects, if: :saved_change_to_state?

  # A goal made from a monobank jar's target: deleting it tells the jar's sync not to make
  # it again. Prepended, so the jar's link row is locked before any row of the goal: the
  # sync (MonobankAccount::JarGoal) locks the link row first too, so the two cannot deadlock.
  before_destroy :release_monobank_jar_goal_links, prepend: true

  scope :alphabetically, -> { order(Arel.sql("LOWER(goals.name) ASC")) }
  scope :not_released, -> { where.not(state: RELEASED_STATES) }

  aasm column: :state, requires_lock: true, whiny_persistence: true do
    after_all_transitions :reset_state_dependent_caches!

    state :active, initial: true
    state :paused
    state :completed
    state :archived

    event :pause do
      transitions from: :active, to: :paused
    end

    event :resume do
      transitions from: :paused, to: :active
    end

    # One-off goals only: completing releases the earmark, the opposite of what a
    # reserve is for. A reserve at 100% is simply whole.
    event :complete do
      transitions from: [ :active, :paused ], to: :completed, guard: :one_off?
    end

    event :archive do
      transitions from: [ :active, :paused, :completed ], to: :archived
    end

    event :unarchive do
      transitions from: :archived, to: :active
    end

    event :reopen do
      transitions from: :completed, to: :active
    end
  end

  class << self
    # Live fixed earmarks of the family, by account:
    # { account_id => [{ goal_id:, allocated_amount: }, ...] }. Injected into every goal
    # of a page so the shared-pool math runs one query, not one per goal.
    def pooled_allocations_for(family)
      GoalAccount.joins(:goal)
                 .where(goals: { family_id: family.id })
                 .where.not(goals: { state: RELEASED_STATES })
                 .pluck(:account_id, :goal_id, :allocated_amount)
                 .group_by(&:first)
                 .transform_values do |triples|
                   triples.map { |(_, goal_id, amount)| { goal_id: goal_id, allocated_amount: amount } }
                 end
    end

    # Cumulative market gain or loss per linked account (sum of balances.net_market_flows),
    # for the contributions basis
    def market_flows_for(family)
      account_ids = linked_account_ids_for(family)
      return {} if account_ids.empty?

      Balance.where(account_id: account_ids).group(:account_id).sum(:net_market_flows)
    end

    # Net Entry amount per linked account and entry currency over the pace window:
    # { account_id => { currency => sum } }. Inflows are negative in Sure.
    def pace_for(family)
      account_ids = linked_account_ids_for(family)
      return {} if account_ids.empty?

      Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: account_ids, date: (Date.current - PACE_WINDOW_DAYS)..Date.current)
        .where(excluded: false)
        .merge(Transaction.excluding_pending)
        .group(:account_id, :currency)
        .sum(:amount)
        .each_with_object({}) do |((account_id, currency), amount), totals|
          (totals[account_id] ||= {})[currency] = amount
        end
    end

    # Goals loaded ready to render: preloads plus the family-wide backing math, so a
    # list of goals does not query once per goal
    def prepared_for(family, scope: family.goals)
      goals = scope.alphabetically.includes(:goal_accounts, :open_pledges, linked_accounts: :account_providers).to_a
      inject_backing_math!(goals, family)
      goals
    end

    def inject_backing_math!(goals, family)
      pooled = pooled_allocations_for(family)
      flows = market_flows_for(family)
      pace_map = pace_for(family)
      converter = CurrencyConverter.new

      goals.each do |goal|
        goal.currency_converter = converter
        goal.pooled_allocations = pooled
        goal.market_flows = flows
        goal.pooled_pace = pace_map
      end
    end

    # Behind first, then on track, then open-ended, paused last, name as tie-breaker
    def active_display_sort(goals)
      goals.sort_by do |goal|
        rank = goal.paused? ? PAUSED_DISPLAY_RANK : ACTIVE_DISPLAY_STATUS_RANK.fetch(goal.status, 4)
        [ rank, goal.name.downcase ]
      end
    end

    # The goals still being worked on (not completed, not archived), ready to render and
    # in the goals index order. The Plan page lists these.
    def active_prepared_for(family)
      active_display_sort(prepared_for(family, scope: family.goals.not_released))
    end

    # The accounts a goal may be funded by: the family's active manual accounts of a
    # fundable type. Bank providers stay hidden in this app.
    def linkable_accounts_for(family)
      family.accounts.counted_in_totals.manual.where(accountable_type: FUNDABLE_ACCOUNT_TYPES)
    end

    # Net inflow into every account linked to the family's goals, in family currency, for
    # the current window and the one before it (the index "Contributed" tile). Transfers
    # between linked accounts net to zero. Each currency's sum is converted at today's
    # rate; a currency without a rate is left out (and logged), never counted at 1.
    def inflow_windows_for(family, window_days: 30, now: Date.current)
      account_ids = linked_account_ids_for(family)
      current_range = (now - window_days)..now
      prior_range = (now - 2 * window_days)..(now - window_days - 1)
      return { current: 0.to_d, prior: 0.to_d } if account_ids.empty?

      sums = Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: account_ids, date: prior_range.begin..current_range.end)
        .where(excluded: false)
        .merge(Transaction.excluding_pending)
        .group(Arel.sql(sanitize_sql_array([ "entries.date >= ?", current_range.begin ])), :currency)
        .sum(:amount)

      totals = { current: 0.to_d, prior: 0.to_d }
      sums.each do |(in_current, entry_currency), amount|
        converted = ExchangeRate.convert_or_leave_out(Money.new(amount, entry_currency), to: family.currency, source: "Goal.inflow_windows_for", family: family)
        next if converted.nil?

        # Inflows are negative in Sure, so the sign flips
        totals[in_current ? :current : :prior] -= converted.amount.to_d
      end
      totals
    end

    # Serialises whole-account claims on one account for the rest of the transaction.
    # The exclusivity check is a read followed by a write, and the write may be an
    # INSERT, so there is no row to lock: a transaction-scoped advisory lock instead.
    def lock_whole_account_claims!(account_id)
      connection.exec_query(
        "SELECT 1 FROM (SELECT pg_advisory_xact_lock($1)) locked",
        "Goal Whole-Account Claim Lock",
        [ ActiveRecord::Relation::QueryAttribute.new(
            "key", whole_account_claim_lock_key(account_id), ActiveRecord::Type::BigInteger.new
          ) ]
      )
    end

    def whole_account_claim_lock_key(account_id)
      Digest::SHA1.hexdigest("goal_accounts:whole_account:#{account_id}").to_i(16) % (2**63)
    end

    private
      def linked_account_ids_for(family)
        GoalAccount.joins(:goal).where(goals: { family_id: family.id }).distinct.pluck(:account_id)
      end
  end

  attr_writer :pooled_allocations, :market_flows, :pooled_pace, :currency_converter

  # Whole-account links held by other live goals of this family on `account_ids`: the
  # links that would double-count a balance if this goal claimed one of those accounts
  # in full too. Shared by GoalAccount's exclusivity check and the restore guard, so the
  # two cannot disagree. `excluding_link_id` is the row being written (a link moving to
  # another goal still carries its old goal_id in the database).
  def whole_account_conflicts_on(account_ids, excluding_link_id: nil)
    ids = Array(account_ids).compact
    return GoalAccount.none if ids.empty?

    # In id order, so two goals claiming the same accounts in opposite orders cannot
    # deadlock. Taking a lock the transaction already holds costs nothing.
    ids.sort.each { |account_id| self.class.lock_whole_account_claims!(account_id) }

    scope = GoalAccount.joins(:goal)
                       .where(account_id: ids, allocated_amount: nil)
                       .where(goals: { family_id: family_id })
                       .where.not(goals: { state: RELEASED_STATES })
    scope = scope.where.not(goal_id: id) if persisted?
    scope = scope.where.not(id: excluding_link_id) if excluding_link_id
    scope
  end

  def one_off?
    kind == "one_off"
  end

  def maintained?
    kind == "maintained"
  end

  def months_of_expenses_target?
    target_mode == "months_of_expenses"
  end

  def contributions_basis?
    progress_basis == "contributions"
  end

  # ---------------------------------------------------------------------------
  # Backing: how much of the linked accounts counts toward this goal
  # ---------------------------------------------------------------------------

  # In goal currency. Each account's share is worked out in the account's own currency
  # first, then converted, so goals in different currencies can share fixed earmarks.
  # A closed goal reports what it reached (completed_amount), not what its accounts hold
  # now. The guard is present?, not completed?: a goal archived straight from active
  # never froze a figure and keeps the live calculation.
  def current_balance
    return completed_amount.to_d if completed_amount.present?

    @current_balance ||= linked_accounts.sum { |account| account_backing(account).amount }
  end

  def current_balance_money
    @current_balance_money ||= Money.new(current_balance, currency)
  end

  # This goal's share of one linked account, in goal currency. A missing rate counts as
  # zero and is recorded for the currency warning.
  def account_backing(account)
    convert_money(account_native_backing(account))
  end

  # This goal's share of one linked account, in the account's currency
  def account_native_backing(account)
    Money.new(account_amount_for(account), account.currency)
  end

  # This goal's backing drawn from a given set of accounts, in `currency`. The budget's
  # free-cash panel (goals-free-cash) asks how much of its accounts is spoken for.
  def backing_within(account_ids, currency: self.currency)
    ids = Array(account_ids).to_set
    linked_accounts
      .select { |account| ids.include?(account.id) }
      .sum { |account| convert_money(account_native_backing(account), to: currency).amount }
  end

  # Market value of the backing (balance basis whatever the progress basis), shown next
  # to the contributions figure of an investment-backed goal
  def market_value_money
    amount = linked_accounts.sum do |account|
      convert_money(Money.new(backing_share_for(account, account.balance.to_d), account.currency)).amount
    end
    Money.new(amount, currency)
  end

  # Strict conversion for writes: an unavailable rate raises Money::ConversionError
  def convert_money!(money, to: currency, date: Date.current)
    currency_converter.convert(money, to: to, date: date)
  end

  # Conversion for read surfaces: an amount without a rate is left out (zero) and its
  # currency is recorded, so the page shows the known subtotal with a warning. Never at 1.
  def convert_money(money, to: currency, date: Date.current)
    convert_money!(money, to: to, date: date)
  rescue Money::ConversionError => e
    # Logged once a day per family and pair: reads run on every page view
    if missing_exchange_rate_currencies.add?(e.from_currency) &&
       Rails.cache.write([ "goal_fx_missing", family_id, e.from_currency, e.to_currency ], true, expires_in: 1.day, unless_exist: true)
      DebugLogEntry.capture(
        category: "goal_currency_conversion", level: "warn", source: "Goal",
        message: "Goal amount could not be converted", family: family,
        metadata: { goal_id: id, from: e.from_currency, to: e.to_currency, date: e.date.to_s }
      )
    end
    Money.new(0, to)
  end

  def missing_exchange_rate_currencies
    @missing_exchange_rate_currencies ||= Set.new
  end

  # Runs the backing, pace and market-value conversions first, so the warning can
  # render above those figures
  def currency_conversion_incomplete?
    current_balance
    pace
    market_value_money
    missing_exchange_rate_currencies.any?
  end

  # ---------------------------------------------------------------------------
  # Progress
  # ---------------------------------------------------------------------------

  # What is still to be found. Money already spent on what the goal was for
  # (consumed_amount, goal-spending) counts as found.
  def remaining_amount
    @remaining_amount ||= [ target_amount.to_d - current_balance.to_d - consumed_amount.to_d, 0 ].max
  end

  def remaining_amount_money
    @remaining_amount_money ||= Money.new(remaining_amount, currency)
  end

  # What progress counts: money still held for the goal plus money already spent on it
  def progress_amount
    current_balance.to_d + consumed_amount.to_d
  end

  def progress_amount_money
    @progress_amount_money ||= Money.new(progress_amount, currency)
  end

  def consumed_amount_money
    @consumed_amount_money ||= Money.new(consumed_amount.to_d, currency)
  end

  def any_consumption?
    consumed_amount.to_d.positive?
  end

  # ---------------------------------------------------------------------------
  # Spending from a goal (w2-goals goal-spending)
  # ---------------------------------------------------------------------------

  # Whether a spend can be recorded from these accounts: the lifecycle panel and the
  # header menu both ask this, so the two ways into the dialog agree
  def spendable_within?(account_ids)
    one_off? && active? && backing_within(account_ids).to_d.positive?
  end

  # One family, so every linked account is the reader's
  def spendable?
    spendable_within?(linked_accounts.map(&:id))
  end

  # Records that `amount` (goal currency) was spent on what the goal was for. Progress
  # keeps counting it (consumed_amount), and the link gives up the same amount, so the
  # spent money stops being reserved against the sibling goals on that account.
  #
  # `account:` may be left out only when the goal has one link, or when `transaction:`
  # names it. `transaction:` anchors the spend on an outflow: it is stamped in
  # extra["goal"]["consumed_goal_id"], and a second claim on it is refused.
  #
  # The amount is converted to the account's currency by the nearest-rate rule on the
  # outflow's date (today without one). No rate refuses the spend; never at 1.
  def consume!(amount, account: nil, transaction: nil)
    amount = amount.to_d
    # A part of a split is claimed through its split, the line the bank sent, so a
    # later split or unsplit cannot offer the same money again
    transaction = transaction.entry.parent_entry.entryable if transaction&.entry&.split_child?
    raise ConsumptionRefused.new(:non_positive) unless amount.positive?
    # A reserve is drawn down and refilled: its shortfall already says so
    raise ConsumptionRefused.new(:maintained) if maintained?

    account ||= transaction&.entry&.account
    link = consumption_link_for(account)
    if transaction && transaction.entry&.account_id != link.account_id
      raise ConsumptionRefused.new(:account_not_linked)
    end

    rate = convert_money!(Money.new(1, link.account.currency), date: transaction&.entry&.date || Date.current).amount
    native_amount = amount / rate

    # The goal is locked, not only the link: two requests locking their own links would
    # both read the same consumed_amount and both pass the target check
    with_lock do
      raise ConsumptionRefused.new(:not_active) unless active?
      raise ConsumptionRefused.new(:exceeds_target) if consumed_amount.to_d + amount > target_amount.to_d

      link.lock!
      stamp_consumption!(transaction) if transaction

      if link.allocated_amount.present?
        # Refused, not clamped: a clamp would count money as spent that the link never
        # released
        raise ConsumptionRefused.new(:exceeds_earmark) if native_amount > link.allocated_amount.to_d

        link.update!(allocated_amount: link.allocated_amount.to_d - native_amount)
      else
        # A whole-account link has no slice to shrink. It now claims what the goal still
        # needs after this spend, capped at what it backs. This gives the same answer
        # whether the outflow is already in the balance or arrives later.
        backed = account_amount_for(link.account).to_d
        raise ConsumptionRefused.new(:exceeds_earmark) if native_amount > backed

        still_needed = target_amount.to_d - consumed_amount.to_d - amount
        link.update!(allocated_amount: [ backed, still_needed / rate ].min.round(4))
      end

      update!(consumed_amount: consumed_amount.to_d + amount)
    end

    # reload refreshes the columns but not the memos, and the link's earmark moved
    reload
    reset_state_dependent_caches!
    self
  rescue Money::ConversionError
    raise ConsumptionRefused.new(:missing_exchange_rate)
  end

  def progress_percent
    return @progress_percent if defined?(@progress_percent)

    @progress_percent = if completed?
      100
    elsif target_amount.to_d.zero?
      0
    elsif remaining_amount.to_d.zero?
      100
    else
      ((progress_amount / target_amount.to_d) * 100).floor.clamp(0, 99)
    end
  end

  # Day precision, so a deadline two days out asks for about 0.07 months of saving
  # rather than jumping between "this month" and "nothing left"
  def months_remaining
    return nil unless target_date

    days = (target_date - Date.current).to_i
    [ (days / 30.0), 0.0 ].max
  end

  def monthly_target_amount
    return @monthly_target_amount if defined?(@monthly_target_amount)

    @monthly_target_amount = if target_date.nil?
      nil
    elsif months_remaining.zero?
      remaining_amount
    else
      (remaining_amount.to_d / months_remaining.to_d).ceil(2)
    end
  end

  # Monthly pace: net inflow into the linked accounts over the last 90 days, divided by
  # three. Transfers between linked accounts net to zero; a transfer in from outside
  # counts. Converted at today's rate, not per entry date (an estimate, and a rate per
  # entry could reach the provider up to 90 times per currency on every render).
  #
  # Whole-account inflow even for an earmarked goal: earmark-aware pace is a deliberate
  # follow-up upstream, so the basis stays as it is.
  def pace
    return @pace if defined?(@pace)

    @pace = if linked_accounts.empty?
      0.to_d
    else
      net = linked_accounts.sum do |account|
        pooled_pace.fetch(account.id, {}).sum do |entry_currency, amount|
          convert_money(Money.new(amount, entry_currency.presence || account.currency)).amount
        end
      end
      (-net.to_d / 3).round(2)
    end
  end

  def pace_money
    @pace_money ||= Money.new(pace, currency)
  end

  # Months of cash on hand at the current pace (open-ended goals only)
  def months_of_runway
    return nil if target_date.present?
    return nil unless pace.positive?

    (current_balance.to_d / pace.to_d).round(1)
  end

  # What the goal still needs per month beyond its current pace. Open pledges reduce it
  # once goal-pledges lands (pending_pledged_amount).
  def catch_up_delta_money
    return Money.new(0, currency) if monthly_target_amount.nil?

    delta = [ monthly_target_amount.to_d - pace.to_d - pending_pledged_amount, 0 ].max
    Money.new(delta, currency)
  end

  # Open pledge total in goal currency (a pledge is always in the goal's currency).
  # Counted as this month's inflow, so the catch-up figure does not ask for money the
  # user has just pledged.
  def pending_pledged_amount
    open_pledges.sum { |pledge| pledge.amount.to_d }
  end

  # ---------------------------------------------------------------------------
  # Pledges (w2-goals goal-pledges)
  # ---------------------------------------------------------------------------

  # The date of the entry that kept the latest pledge, nil when none has been kept.
  # The entry's date, not the pledge's updated_at, so it reads the same after a resave.
  def last_matched_pledge_on
    return @last_matched_pledge_on if defined?(@last_matched_pledge_on)

    @last_matched_pledge_on = goal_pledges.where(status: "matched").maximum(:matched_on)
  end

  def last_matched_pledge_days_ago
    last = last_matched_pledge_on
    last && (Date.current - last).to_i
  end

  # The pledge button says what the user just did: a transfer for an investment or
  # linked account, money set aside for a manual cash account
  def pledge_action_label_key
    pledges_use_transfer? ? "goals.show.pledge_just_transferred" : "goals.show.pledge_just_saved"
  end

  def pledges_use_transfer?
    linked_accounts.any? { |account| account.default_pledge_kind == "transfer" }
  end

  # Whether the goal page offers a new pledge: a goal still being funded
  def accepts_pledges?
    active? && !(status == :reached || status == :funded) && linked_accounts.any?
  end

  # ---------------------------------------------------------------------------
  # Status
  # ---------------------------------------------------------------------------

  def display_status
    return @display_status if defined?(@display_status)

    @display_status = if archived?
      :archived
    elsif paused?
      :paused
    elsif completed?
      :completed
    else
      status
    end
  end

  # One-off: :reached, :no_target_date, :on_track or :behind. A reserve is never
  # "reached": it is either :funded (at its floor) or :depleted (short).
  def status
    return @status if defined?(@status)
    return @status = (remaining_amount.to_d.zero? ? :funded : :depleted) if maintained?

    @status = if completed? || remaining_amount.to_d.zero?
      :reached
    elsif target_date.nil?
      :no_target_date
    elsif monthly_target_amount.to_d <= pace.to_d
      :on_track
    else
      :behind
    end
  end

  # The one definition of "behind pace" for counts and copy. A paused goal stopped the
  # pace clock on purpose, and a reserve has no pace at all.
  def behind_pace?
    !paused? && !maintained? && status == :behind
  end

  # A goal off its pace, or a reserve below its floor
  def needs_attention?
    status.in?(%i[behind depleted])
  end

  # ---------------------------------------------------------------------------
  # Months-of-expenses reserves
  # ---------------------------------------------------------------------------

  # Recomputes this reserve's floor. Returns the new amount when it wrote one, nil when
  # it did not (no spending history yet, no rate, or no change): the previous target
  # stands, because zero would silently declare the reserve complete.
  def refresh_target_from_expenses!
    computed = months_of_expenses_amount
    return nil if computed.nil? || computed == target_amount.to_d

    update!(target_amount: computed)
    computed
  end

  # Whether a months-based target can be worked out at all right now (is there spending
  # history to derive it from). With none, the form keeps the typed amount field.
  def months_target_derivable?
    return false if family.nil? || currency.blank?

    median = median_monthly_expense
    return false unless median.positive?

    convert_to_goal_currency(median).to_d.positive?
  end

  # ---------------------------------------------------------------------------
  # Presentation
  # ---------------------------------------------------------------------------

  # One colour rule for the progress ring, on the goal card and the goal page:
  # green when the goal is where it should be, amber when it needs money, grey
  # otherwise (no date, paused, archived)
  def progress_tone
    case status
    when :reached, :on_track, :funded then :success
    else needs_attention? ? :warning : :neutral
    end
  end

  # Data for the projection chart: the 90-day saved line, the target line and the pace
  # projection, with the labels pre-formatted so the controller only draws.
  def projection_payload
    series_values = balance_series_values
    # The series tracks the whole linked balances. Scaled to this goal's backing so the
    # saved line meets current_balance at today (exact for whole-balance goals). Capped
    # at 1: a closed goal's frozen figure can exceed what its accounts hold now.
    whole_total = linked_accounts.sum do |account|
      convert_money(Money.new(account.balance.to_d, account.currency)).amount
    end
    backing_ratio = whole_total.positive? ? (current_balance.to_d / whole_total) : 0.to_d
    backing_ratio = 1.to_d if backing_ratio > 1
    saved_series = series_values.map { |v| { date: v.date.to_s, value: (v.value.amount.to_d * backing_ratio).to_f } }

    earliest = series_values.first&.date || created_at.to_date
    target_amt = target_amount.to_d
    proj_end = projection_end_amount

    {
      saved_series: saved_series,
      start_date: earliest.to_s,
      today: Date.current.to_s,
      target_date: target_date&.to_s,
      target_amount: target_amt.to_f,
      target_amount_label: Money.new(target_amt, currency).format(precision: 0),
      target_amount_short_label: short_money(target_amt, currency),
      currency_symbol: Money.new(0, currency).currency.symbol,
      current_amount: current_balance.to_f,
      avg_monthly: pace.to_f,
      required_monthly: monthly_target_amount&.to_f,
      currency: currency,
      status: status.to_s,
      projection_end_value: proj_end.to_f,
      projection_end_label: Money.new(proj_end, currency).format(precision: 0),
      projection_shortfall_label: (target_amt > proj_end ? Money.new(target_amt - proj_end, currency).format(precision: 0) : nil)
    }
  end

  # Projected balance at the target date at the current pace (mirrors the chart)
  def projection_end_amount
    return current_balance.to_d if target_date.nil?

    months = ((target_date - Date.current).to_f / 30.44).clamp(0.0, Float::INFINITY)
    projected = current_balance.to_d + (pace.to_d * months.to_d)
    [ current_balance.to_d, projected ].max
  end

  # { account_id => palette colour } for the linked accounts, stable within a goal so the
  # index card stack and the show page breakdown agree. Sorted by id so it does not
  # shuffle when the accounts load in another order.
  # Deterministic color pick from the palette so the same string maps to the
  # same color across processes (Ruby's String#hash is randomized per boot).
  def self.color_for_name(name)
    return COLORS.first if name.blank?
    COLORS[Digest::MD5.hexdigest(name).to_i(16) % COLORS.size]
  end

  # The one colour an account wears for this goal: in the form, the account
  # stack on the card and the funding breakdown. A linked account takes its
  # slot in the goal's map; any other account (the form lists them all) its
  # name-hashed pick.
  def account_color(account)
    account_color_map[account.id] || self.class.color_for_name(account.name)
  end

  def account_color_map
    @account_color_map ||= begin
      palette = COLORS
      linked_accounts.sort_by(&:id).each_with_index.to_h do |account, i|
        [ account.id, palette[i % palette.size] ]
      end
    end
  end

  # Shared by the show page menu and the index card menu. Deleting a goal removes only
  # the goal, its account links and its pledges; accounts, balances and transactions stay.
  def deletion_confirm
    CustomConfirm.new(
      destructive: true,
      high_severity: true,
      title: I18n.t("goals.show.confirm_delete_title"),
      body: I18n.t("goals.show.confirm_delete_body", name: name),
      btn_text: I18n.t("goals.show.confirm_delete_cta")
    )
  end

  # One line between the header and the ring on the show page. nil when the lifecycle
  # panel already says it (paused, archived, completed, reached).
  def status_callout_context
    return nil if paused? || archived? || completed? || status == :reached

    case status
    when :behind
      delta = catch_up_delta_money
      if delta.amount.positive?
        I18n.t("goals.show.status_callout.behind", amount: delta.format(precision: 0))
      else
        I18n.t("goals.show.status_callout.behind_covered")
      end
    when :on_track
      if target_date && pace.to_d.positive?
        months = (remaining_amount.to_d / pace.to_d).ceil
        I18n.t("goals.show.status_callout.on_track", date: I18n.l(Date.current >> months.to_i, format: "%b %Y"))
      end
    when :no_target_date
      I18n.t("goals.show.status_callout.no_target_date")
    when :depleted
      I18n.t("goals.show.status_callout.depleted", amount: remaining_amount_money.format(precision: 0))
    end
  end

  # The segments of the header line under the goal name, kept apart so the view can
  # stop a short one ("184 days left") breaking mid-phrase
  def header_summary_parts
    parts = []
    reached = completed? || status == :reached

    if target_date
      days = (target_date - Date.current).to_i
      amount = target_amount_money.format(precision: 0)
      date = I18n.l(target_date, format: :long)

      if days < 0 && !reached
        parts << I18n.t("goals.show.header.target_by_past", amount: amount, date: date)
      else
        parts << I18n.t("goals.show.header.target_by", amount: amount, date: date)
        parts << I18n.t("goals.goal_card.days_left", count: days) if days > 0 && !reached
      end
    else
      parts << I18n.t("goals.show.header.target", amount: target_amount_money.format(precision: 0))
    end

    parts
  end

  # The projection-chart subtitle and the chart's aria description. Returns an
  # html_safe string for the _html variant.
  def projection_summary
    return @projection_summary if defined?(@projection_summary)

    @projection_summary =
      if maintained?
        I18n.t("goals.show.projection.reserve")
      elsif completed? || progress_percent >= 100
        I18n.t("goals.show.projection.reached")
      elsif target_date.nil?
        I18n.t("goals.show.projection.no_target_date")
      elsif monthly_target_amount && pace.to_d < monthly_target_amount.to_d
        I18n.t("goals.show.projection.behind")
      elsif pace.positive?
        months = (remaining_amount.to_d / pace.to_d).ceil
        I18n.t("goals.show.projection.on_track_html", date: I18n.l(Date.current >> months.to_i, format: "%b %Y"))
      else
        I18n.t("goals.show.projection.no_pace")
      end
  end

  private
    # ---- backing math ----

    # This goal's amount from one linked account under its progress basis: net
    # contributions (market gains out, floored at 0) or the live balance
    def account_amount_for(account)
      base = contributions_basis? ? net_contributed_for(account) : account.balance.to_d
      backing_share_for(account, base)
    end

    # Current value minus cumulative market gain or loss, floored at 0. Depository
    # accounts have no market flows, so this is their balance.
    def net_contributed_for(account)
      market_gain = (market_flows[account.id] || 0).to_d
      [ account.balance.to_d - market_gain, 0.to_d ].max
    end

    # This goal's share of one account given its base amount. The goal's own earmark is
    # read from its own links (right even for a released goal, which the pool leaves
    # out); other live goals' fixed earmarks come from the pool. A fixed earmark takes
    # its slice; a whole-balance link takes what the others leave. When the fixed
    # earmarks exceed the base they are cut pro rata, so the shares never sum past it.
    # A non-positive base backs nothing.
    def backing_share_for(account, base)
      base = base.to_d
      return 0.to_d if base <= 0

      mine = own_allocation_for(account)
      others_fixed = (pooled_allocations[account.id] || [])
        .reject { |row| row[:goal_id] == id }
        .sum { |row| row[:allocated_amount].to_d }

      if mine
        total_fixed = others_fixed + mine
        total_fixed > base && total_fixed.positive? ? (mine * (base / total_fixed)).round(4) : mine
      else
        [ base - others_fixed, 0 ].max
      end
    end

    # This goal's earmark on `account`: a BigDecimal, or nil for a whole-balance link
    def own_allocation_for(account)
      goal_accounts.find { |link| link.account_id == account.id }&.allocated_amount&.to_d
    end

    def currency_converter
      @currency_converter ||= CurrencyConverter.new
    end

    def pooled_allocations
      @pooled_allocations ||= self.class.pooled_allocations_for(family)
    end

    def market_flows
      @market_flows ||= self.class.market_flows_for(family)
    end

    def pooled_pace
      @pooled_pace ||= self.class.pace_for(family)
    end

    # The 90-day balance series of the linked accounts in goal currency. The fork's
    # series builder leaves an account without a rate out of the sum, which would draw a
    # drop that never happened, so a missing currency empties the series and shows the
    # currency warning instead.
    def balance_series_values
      return [] if linked_accounts.empty?

      missing = ExchangeRate.currencies_without_rate(linked_accounts.map(&:currency), to: currency)
      if missing.any?
        missing.each { |code| missing_exchange_rate_currencies << code }
        return []
      end

      Balance::ChartSeriesBuilder.new(
        account_ids: linked_accounts.map(&:id),
        currency: currency,
        period: Period.last_90_days
      ).balance_series.values
    rescue StandardError => e
      # The chart drops to the target line only, and the failure is reported
      Rails.logger.error("Goal##{id} balance series failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      []
    end

    # K/M shorthand for narrow chart annotations
    def short_money(amount, code)
      amount_f = amount.to_f
      symbol = Money.new(0, code).currency.symbol
      abs = amount_f.abs
      if abs >= 1_000_000
        short = (amount_f / 1_000_000.0).round(1)
        "#{symbol}#{short == short.to_i ? short.to_i : short}M"
      elsif abs >= 1_000
        short = (amount_f / 1_000.0).round(1)
        "#{symbol}#{short == short.to_i ? short.to_i : short}K"
      else
        "#{symbol}#{amount_f.round.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}"
      end
    end

    # ---- months-of-expenses ----

    # The family's median monthly spend in family currency, over the fork's fiscal
    # months (IncomeStatement::FamilyStats leaves transfers, one-time and card payments
    # out). The current period is left out: on the first day of a fiscal month it holds
    # a day of spending and would drag the median down. Not memoized: the refresh job
    # derives again on an instance it has already saved through.
    def median_monthly_expense
      IncomeStatement.new(family).median_expense(interval: "month", exclude_current_period: true).to_d
    end

    def months_of_expenses_amount
      return nil unless maintained? && months_of_expenses_target? && target_months.to_i.positive?

      median = median_monthly_expense
      return nil unless median.positive?

      computed = (median * target_months).round(2)
      return nil unless computed.positive?

      # The median is in family currency; target_amount is in the goal's
      converted = convert_to_goal_currency(computed)
      converted&.positive? ? converted : nil
    end

    # nil when there is no rate: the previous target stands, as with no spending history
    def convert_to_goal_currency(amount)
      return amount.to_d if currency == family.currency

      convert_money!(Money.new(amount, family.currency)).amount.round(2)
    rescue Money::ConversionError
      nil
    end

    # With nothing to derive from, a typed figure on an existing reserve is put back: a
    # stale floor beats a wrong one wearing a "computed" label
    def apply_months_of_expenses_target
      computed = months_of_expenses_amount
      return self.target_amount = computed if computed

      self.target_amount = target_amount_in_database if target_amount_changed? && !new_record?
    end

    # ---- spending ----

    # Claims the outflow for this goal. Inside the caller's lock, so a refusal here rolls
    # the whole spend back. Written beside the fork's other extra keys (exchange_rate,
    # replaced_subscription_charge) and a pledge's pledge_id under the same "goal" key.
    def stamp_consumption!(txn)
      txn.with_lock do
        raise ConsumptionRefused.new(:transaction_already_claimed) if txn.extra&.dig("goal", "consumed_goal_id").present?

        extra = (txn.extra || {}).deep_dup
        extra["goal"] = (extra["goal"] || {}).merge("consumed_goal_id" => id)
        txn.update!(extra: extra)
      end
    end

    def consumption_link_for(account)
      links = goal_accounts.to_a
      raise ConsumptionRefused.new(:no_linked_account) if links.empty?

      if account.nil?
        raise ConsumptionRefused.new(:account_required) if links.size > 1

        return links.first
      end

      links.find { |link| link.account_id == account.id } ||
        raise(ConsumptionRefused.new(:account_not_linked))
    end

    # ---- lifecycle ----

    def prepare_completion_conversion
      linked_accounts.each { |account| convert_money!(account_native_backing(account)) }
    rescue Money::ConversionError
      errors.add(:base, :missing_exchange_rate)
    end

    def apply_state_change_side_effects
      previous_state, next_state = saved_change_to_state

      # Anything read between the transition and the save refilled the memos from the
      # old state; cleared so the closing figure below is current
      reset_state_dependent_caches!

      if next_state == "completed"
        # Freeze what the goal reached, so spending the money does not rewrite it
        closing_balance = linked_accounts.sum { |account| convert_money!(account_native_backing(account)).amount }
        update_columns(completed_amount: closing_balance, completed_at: Time.current)
      elsif previous_state.in?(RELEASED_STATES) && !next_state.in?(RELEASED_STATES)
        thaw_completed_amount!
      end
    end

    # Reopening or unarchiving hands the goal back to the live calculation. A goal that
    # closed a lifecycle (it froze a figure) also starts its spending over; one archived
    # straight from active keeps what it recorded as spent.
    def thaw_completed_amount!
      attrs = { completed_amount: nil, completed_at: nil }
      attrs[:consumed_amount] = 0 if completed_amount.present?
      update_columns(**attrs)
    end

    # The state drives the status memos and the balance memos (a released goal leaves
    # the pool, a completed one reads its frozen figure), so all are cleared on a
    # transition
    def reset_state_dependent_caches!
      %i[
        @display_status @projection_summary
        @current_balance @current_balance_money
        @remaining_amount @remaining_amount_money
        @progress_percent @monthly_target_amount
        @progress_amount_money @consumed_amount_money
        @pace @pace_money @status @pooled_allocations @missing_exchange_rate_currencies
      ].each do |ivar|
        remove_instance_variable(ivar) if instance_variable_defined?(ivar)
      end
    end

    # ---- validations and callbacks ----

    def must_have_at_least_one_linked_account
      return unless goal_accounts.reject(&:marked_for_destruction?).empty?

      errors.add(:base, :at_least_one_linked_account_required)
    end

    def linked_accounts_must_be_fundable
      offending = goal_accounts.reject(&:marked_for_destruction?).reject do |link|
        FUNDABLE_ACCOUNT_TYPES.include?(link.account&.accountable_type)
      end
      return if offending.empty?

      errors.add(:linked_accounts, :must_be_fundable)
    end

    def linked_accounts_must_belong_to_family
      return if family.nil?

      foreign = goal_accounts.reject(&:marked_for_destruction?).reject do |link|
        link.account.nil? || link.account.family_id == family_id
      end
      return if foreign.empty?

      errors.add(:linked_accounts, :must_belong_to_family)
    end

    # Goals funded by an investment or crypto account measure contributions, so a market
    # swing does not move them. Only while the basis is still the default.
    def default_progress_basis_for_market_accounts
      return unless goal_accounts.any? { |link| link.account&.balance_type == :investment }
      return unless progress_basis.blank? || progress_basis == "balance"

      self.progress_basis = "contributions"
    end

    def currency_locked_once_linked
      return unless persisted? && currency_changed?
      return unless goal_accounts.where.not(id: nil).exists?

      errors.add(:currency, :locked_after_linked)
    end

    # Turning a released goal into a reserve would leave a reserve in a state that has
    # handed its earmark back. The persisted state is read, so one update cannot set
    # `state: "active"` alongside the new kind and skip the reopen transition.
    def kind_locked_while_released
      return unless persisted? && will_save_change_to_kind?
      return unless state_in_database.in?(RELEASED_STATES)

      errors.add(:kind, :locked_while_released)
    end

    # A reserve refuses spending, so a goal that has recorded some cannot become one
    def kind_locked_once_consumed
      return unless will_save_change_to_kind? && maintained?
      return unless consumed_amount.to_d.positive?

      errors.add(:kind, :locked_once_consumed)
    end

    def target_must_cover_what_was_consumed
      return unless target_amount.present? && consumed_amount.to_d.positive?
      return if target_amount.to_d >= consumed_amount.to_d

      errors.add(:target_amount, :below_consumed)
    end

    # target_months means something only for a reserve in months mode
    def months_target_requires_a_reserve
      return if target_mode == "fixed" && target_months.blank?
      return if months_of_expenses_target? && maintained? && target_months.present?

      if months_of_expenses_target? && !maintained?
        errors.add(:target_mode, :months_requires_maintained)
      elsif months_of_expenses_target?
        errors.add(:target_months, :blank)
      else
        errors.add(:target_months, :only_with_months_mode)
      end
    end

    def clear_target_date_for_maintained
      self.target_date = nil if maintained?
    end

    # Archiving frees the accounts a goal claimed in full, so another goal may claim one
    # meanwhile. Restoring would then put two whole-account links on one account; a state
    # change writes no link, so GoalAccount's check never sees it. A validation, not an
    # AASM guard, so the user reads which goal holds the account.
    def restore_must_not_recreate_whole_account_conflict
      return unless will_save_change_to_state?

      previous_state, next_state = state_change_to_be_saved
      return unless previous_state.in?(RELEASED_STATES)
      return if next_state.in?(RELEASED_STATES)

      conflict = whole_account_conflicts_on(own_whole_account_ids).first
      return if conflict.nil?

      errors.add(:base, :whole_account_conflict_on_restore, goal_name: conflict.goal.name, account_name: conflict.account.name)
    end

    def lock_whole_account_claims_in_order
      ids = own_whole_account_ids
      ids |= goal_accounts.filter_map { |link| link.account_id if link.will_save_change_to_allocated_amount? }
      ids.compact.uniq.sort.each { |account_id| self.class.lock_whole_account_claims!(account_id) }
    end

    def release_monobank_jar_goal_links
      links = MonobankJarGoalLink.where(goal_id: id).lock.to_a
      return if links.empty?

      MonobankJarGoalLink.where(id: links.map(&:id)).update_all(goal_id: nil, dismissed_at: Time.current, updated_at: Time.current)
    end

    # Accounts this goal claims in full, from the loaded links (right for unsaved ones too)
    def own_whole_account_ids
      goal_accounts.reject(&:marked_for_destruction?).select(&:whole_account?).filter_map(&:account_id)
    end
end
