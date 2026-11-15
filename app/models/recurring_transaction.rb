class RecurringTransaction < ApplicationRecord
  include Monetizable
  include AASM

  belongs_to :family
  belongs_to :merchant, optional: true
  belongs_to :category, optional: true
  belongs_to :subscription_service, optional: true
  belongs_to :default_account, class_name: "Account", optional: true
  belongs_to :inferred_account, class_name: "Account", optional: true

  has_many :transactions, dependent: :nullify

  has_one_attached :logo

  monetize :amount
  monetize :expected_amount_min, allow_nil: true
  monetize :expected_amount_max, allow_nil: true
  monetize :expected_amount_avg, allow_nil: true

  enum :status, { active: "active", inactive: "inactive" }
  enum :billing_cycle, { monthly: "monthly", yearly: "yearly" }, prefix: true

  # Why an inactive row is inactive. Only stale rows come back on their own.
  INACTIVE_REASONS = %w[user stale].freeze

  # Transaction kinds that are never a recurring bill or income: transfer legs,
  # moves into investments, and spending the user marked as one-time.
  NON_RECURRING_KINDS = (Transaction::TRANSFER_KINDS + %w[investment_contribution one_time]).freeze

  # Lifecycle of a recurring row as a subscription:
  #   pattern      - detected recurring pattern, not a subscription
  #   suggested    - suggested to the user as a subscription
  #   dismissed    - suggestion the user dismissed; it stays dismissed
  #   subscription - confirmed subscription (approved or created by the user)
  # is_subscription and suggestion_status are legacy mirrors of this state,
  # written on save for the previous app version; nothing reads them.
  aasm :subscription_state, column: :subscription_state, whiny_persistence: true do
    state :pattern, initial: true
    state :suggested
    state :dismissed
    state :subscription

    event :suggest do
      transitions from: :pattern, to: :suggested
    end

    event :approve do
      transitions from: %i[pattern suggested dismissed], to: :subscription
    end

    event :dismiss, before: -> { self.dismissed_at = Time.current } do
      transitions from: :suggested, to: :dismissed
    end

    event :restore, before: -> { self.dismissed_at = nil } do
      transitions from: :dismissed, to: :suggested
    end
  end

  validates :amount, presence: true
  validates :currency, presence: true
  validates :expected_day_of_month, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 31 }
  validates :expected_month, presence: true, if: -> { is_subscription? && billing_cycle_yearly? }
  validates :expected_month, numericality: { in: 1..12 }, allow_nil: true
  validates :inactive_reason, inclusion: { in: INACTIVE_REASONS }, allow_nil: true
  validate :merchant_or_name_present
  validate :amount_variance_consistency

  before_save :write_legacy_subscription_columns

  def merchant_or_name_present
    if merchant_id.blank? && name.blank?
      errors.add(:base, "Either merchant or name must be present")
    end
  end

  def amount_variance_consistency
    return unless manual?

    if expected_amount_min.present? && expected_amount_max.present?
      if expected_amount_min > expected_amount_max
        errors.add(:expected_amount_min, "cannot be greater than expected_amount_max")
      end
    end
  end

  scope :for_family, ->(family) { where(family: family) }
  scope :expected_soon, -> { active.where("next_expected_date <= ?", 1.month.from_now) }
  scope :subscriptions, -> { where(subscription_state: "subscription") }
  scope :active_subscriptions, -> { subscriptions.active }
  # Rows the user created or confirmed (see #user_managed?).
  scope :user_managed, -> { where(manual: true).or(where(subscription_state: "subscription")) }
  # Manual rows that are not subscriptions ("Other recurring" on Subscriptions).
  scope :other_recurring, -> { where(manual: true).where.not(subscription_state: "subscription") }

  # Rows with the same identity as the given merchant or name and currency.
  # Amount is not part of the identity: it drifts with FX rates and prices.
  scope :with_identity, ->(merchant_id:, name:, currency:) {
    base = where(currency: currency)
    merchant_id.present? ? base.where(merchant_id: merchant_id) : base.where(merchant_id: nil, name: name)
  }

  def is_subscription?
    subscription?
  end
  alias_method :is_subscription, :is_subscription?

  # Rows the user created or curated. They use the longer stale threshold
  # and are never deleted automatically.
  def user_managed?
    manual? || subscription?
  end

  # Class methods for identification and cleanup
  # Schedules pattern identification with debounce to run after all syncs complete
  def self.identify_patterns_for(family)
    IdentifyRecurringTransactionsJob.schedule_for(family)
    0 # Return immediately, actual count will be determined by the job
  end

  # Synchronous pattern identification (for manual triggers from UI)
  def self.identify_patterns_for!(family)
    Identifier.new(family).identify_recurring_patterns
  end

  def self.cleanup_stale_for(family)
    Cleaner.new(family).cleanup_stale_transactions
  end

  # Moves recurring rows off a merchant that is being merged, converted,
  # unlinked or deleted, so subscriptions survive with their settings.
  # With to_merchant the rows point at it; without, they become name-based
  # (keeping their name, or taking fallback_name). When the move collides
  # with a row that already has the target identity and amount, the more
  # informative row is kept and the other one's transactions move to it.
  def self.reassign_merchant!(scope, to_merchant: nil, fallback_name: nil)
    scope.find_each do |row|
      target = to_merchant ? { merchant_id: to_merchant.id, name: nil } : { merchant_id: nil, name: row.name.presence || fallback_name }
      # A merchant row is unique per merchant whatever its name, so the lookup must ignore the name too
      identity = to_merchant ? target.slice(:merchant_id) : target

      duplicate = where(family_id: row.family_id, currency: row.currency, amount: row.amount)
        .where(identity)
        .where.not(id: row.id)
        .first

      if duplicate
        keeper, loser = [ row, duplicate ].sort_by(&:merge_rank)
        Transaction.where(recurring_transaction_id: loser.id).update_all(recurring_transaction_id: keeper.id)
        loser.destroy!
        keeper.update!(target) if keeper == row
      else
        row.update!(target)
      end
    end
  end

  # Lower ranks are more informative: rows the user manages, then dismissed
  # and suggested rows, then the most recent occurrence.
  def merge_rank
    state_rank = { "dismissed" => 0, "suggested" => 1 }.fetch(subscription_state, 2)
    [ user_managed? ? 0 : 1, state_rank, -(last_occurrence_date&.jd || 0) ]
  end

  # What mark_from_transaction! did: :created a row, :converted a detected
  # row in place, or found a row the user already manages (:unchanged).
  MarkResult = Data.define(:recurring_transaction, :outcome) do
    def unchanged?
      outcome == :unchanged
    end
  end

  MARK_AS = %i[manual subscription].freeze

  # The row with this identity (merchant or name, currency) whose amount is
  # within the tolerance; the closest one when several match, a subscription
  # first on a tie. Detection and "Mark as recurring" share it, so both land
  # on the same row.
  def self.find_for_identity(family:, merchant_id:, name:, currency:, amount:, excluding: [])
    family.recurring_transactions
      .with_identity(merchant_id: merchant_id, name: name, currency: currency)
      .where.not(id: excluding)
      .to_a
      .select { |recurring| recurring.amount_within_tolerance?(amount) }
      .min_by { |recurring| [ (recurring.amount - amount).abs, recurring.subscription? ? 0 : 1 ] }
  end

  # The row a transaction already belongs to: the subscription that generated
  # it, or a row with its identity and amount.
  def self.find_for_transaction(transaction)
    entry = transaction.entry
    family = entry.account.family
    linked = transaction.recurring_transaction
    return linked if linked && linked.family_id == family.id

    find_for_identity(
      family: family,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      currency: entry.currency,
      amount: entry.amount
    )
  end

  # The row the user manages for this transaction, if any (the transaction
  # drawer shows "Already recurring" for it).
  def self.user_managed_for_transaction(transaction)
    row = find_for_transaction(transaction)
    row if row&.user_managed?
  end

  # "Mark as recurring" / "Mark as subscription" from a transaction. A row the
  # user already manages is returned as it is (a manual row marked as a
  # subscription is confirmed as one). A detected pattern, suggestion or
  # dismissed suggestion with the same identity becomes the manual row, so
  # no second row appears. Otherwise a manual row is created.
  # Raises ActiveRecord::RecordNotUnique when a concurrent write took the identity.
  def self.mark_from_transaction!(source, as: :manual)
    raise ArgumentError, "as must be one of #{MARK_AS.join(", ")}" unless MARK_AS.include?(as)

    existing = find_for_transaction(source)
    if existing&.user_managed? && (as == :manual || existing.subscription?)
      return MarkResult.new(recurring_transaction: existing, outcome: :unchanged)
    end

    outcome = existing ? :converted : :created
    row = nil
    transaction(requires_new: true) do
      row = if existing.nil?
        create_from_transaction(source)
      elsif existing.manual?
        existing # a manual row marked as a subscription keeps what the user set
      else
        existing.adopt_transaction!(source)
      end
      row.confirm_as_subscription! if as == :subscription
    end

    MarkResult.new(recurring_transaction: row, outcome: outcome)
  end

  # Attributes of a manual row for a transaction. The amount variance comes
  # from the matching transactions of the past 6 months.
  def self.manual_attributes_from_transaction(transaction)
    entry = transaction.entry
    expected_day = entry.date.day

    matching_amounts = find_matching_transaction_amounts(
      family: entry.account.family,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      currency: entry.currency,
      expected_day: expected_day,
      lookback_months: 6
    )

    expected_min = matching_amounts.min
    expected_max = matching_amounts.max
    expected_avg = matching_amounts.any? ? matching_amounts.sum / matching_amounts.size : nil

    {
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: expected_day,
      last_occurrence_date: entry.date,
      # Relative to today, not to the transaction date
      next_expected_date: calculate_next_expected_date_from_today(expected_day),
      status: "active",
      inactive_reason: nil,
      occurrence_count: matching_amounts.size,
      manual: true,
      expected_amount_min: expected_min,
      expected_amount_max: expected_max,
      expected_amount_avg: expected_avg,
      inferred_account_id: entry.account_id
    }
  end

  # Create a manual recurring transaction from an existing transaction
  def self.create_from_transaction(transaction)
    family = transaction.entry.account.family
    create!(family: family, **manual_attributes_from_transaction(transaction))
  end

  # Turns a detected row into the manual row for this transaction, keeping its
  # id, subscription state and the newer of the two last occurrences.
  def adopt_transaction!(transaction)
    attributes = self.class.manual_attributes_from_transaction(transaction)
    attributes[:last_occurrence_date] = [ last_occurrence_date, attributes[:last_occurrence_date] ].compact.max
    attributes[:next_expected_date] = [ next_expected_date, attributes[:next_expected_date] ].compact.max
    update!(attributes)
    self
  end

  # Confirms the row as a subscription with the billing cycle of the
  # transaction's history, in the Subscriptions category when there is one.
  def confirm_as_subscription!
    assign_detected_subscription_attributes
    approve!
  end

  # "Make subscription" on an Other recurring row. Like approving a
  # suggestion, it starts from the next future date (no charge is generated
  # for a period nobody confirmed) and pays from the inferred account.
  # Raises AASM::InvalidTransition for a row that already is a subscription.
  def make_subscription!
    assign_detected_subscription_attributes
    self.default_account_id = inferred_account_id if default_account_id.blank?
    roll_next_expected_date_forward
    approve!
  end

  # Whether amount is within the matching tolerance of this row's amount, or
  # of the range a manual row has observed.
  def amount_within_tolerance?(other_amount)
    tolerance = [ amount.abs, other_amount.abs ].max * AMOUNT_TOLERANCE
    return true if (amount - other_amount).abs <= tolerance

    has_amount_variance? &&
      other_amount.between?(expected_amount_min - tolerance, expected_amount_max + tolerance)
  end

  # The family's transaction entries that can be part of a recurring series:
  # no transfer legs, investment contributions or one-time spending.
  def self.recurring_entries_for(family)
    family.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
      .where(entryable_type: "Transaction")
      .where.not(transactions: { kind: NON_RECURRING_KINDS })
  end

  # Find matching transaction entries for variance calculation
  def self.find_matching_transaction_entries(family:, merchant_id:, name:, currency:, expected_day:, lookback_months: 6)
    lookback_date = lookback_months.months.ago.to_date

    entries = recurring_entries_for(family)
      .where(currency: currency)
      .where("entries.date >= ?", lookback_date)
      .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
             [ expected_day - 2, 1 ].max,
             [ expected_day + 2, 31 ].min)
      .order(date: :desc)

    # Filter by merchant or name
    if merchant_id.present?
      entries.where(transactions: { merchant_id: merchant_id }).to_a
    else
      entries.where(name: name).to_a
    end
  end

  # Find matching transaction amounts for variance calculation
  def self.find_matching_transaction_amounts(family:, merchant_id:, name:, currency:, expected_day:, lookback_months: 6)
    matching_entries = find_matching_transaction_entries(
      family: family,
      merchant_id: merchant_id,
      name: name,
      currency: currency,
      expected_day: expected_day,
      lookback_months: lookback_months
    )

    matching_entries.map(&:amount)
  end

  # Calculate next expected date from today
  def self.calculate_next_expected_date_from_today(expected_day)
    today = Date.current

    # Try this month first
    begin
      this_month_date = Date.new(today.year, today.month, expected_day)
      return this_month_date if this_month_date > today
    rescue ArgumentError
      # Day doesn't exist in this month (e.g., 31st in February)
    end

    # Otherwise use next month
    calculate_next_expected_date_for(today, expected_day)
  end

  def self.calculate_next_expected_date_for(from_date, expected_day)
    next_month = from_date.next_month
    begin
      Date.new(next_month.year, next_month.month, expected_day)
    rescue ArgumentError
      next_month.end_of_month
    end
  end

  # Amount tolerance for matching (15% to handle exchange rate fluctuations)
  AMOUNT_TOLERANCE = 0.15

  # Find matching transactions for this recurring pattern
  def matching_transactions
    # For manual recurring with amount variance, match within range
    # For automatic recurring, use tolerance-based matching to handle exchange rate fluctuations
    entries = if manual? && has_amount_variance?
      self.class.recurring_entries_for(family)
        .where(currency: currency)
        .where("entries.amount BETWEEN ? AND ?", expected_amount_min, expected_amount_max)
        .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
               [ expected_day_of_month - 2, 1 ].max,
               [ expected_day_of_month + 2, 31 ].min)
        .order(date: :desc)
    else
      # Use tolerance-based matching (±15%) to handle multi-currency exchange rate fluctuations
      # minmax: for an income row (negative amount) the -15% bound is the larger one.
      tolerance_min, tolerance_max = [ amount * (1 - AMOUNT_TOLERANCE), amount * (1 + AMOUNT_TOLERANCE) ].minmax

      self.class.recurring_entries_for(family)
        .where(currency: currency)
        .where("entries.amount BETWEEN ? AND ?", tolerance_min, tolerance_max)
        .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
               [ expected_day_of_month - 2, 1 ].max,
               [ expected_day_of_month + 2, 31 ].min)
        .order(date: :desc)
    end

    # Filter by merchant or name
    if merchant_id.present?
      entries.where(transactions: { merchant_id: merchant_id })
    else
      # Match by entry name
      entries.where(name: name)
    end
  end

  # Check if this recurring transaction has amount variance configured
  def has_amount_variance?
    expected_amount_min.present? && expected_amount_max.present?
  end

  # How long a row may go without an occurrence before it counts as stale.
  # Rows the user created or curated get longer than detected patterns, and
  # a yearly cycle must outlast the gap between two charges.
  def stale_after
    return 2.months unless user_managed?

    billing_cycle_yearly? ? 14.months : 6.months
  end

  # Check if this recurring transaction should be marked inactive
  def should_be_inactive?
    return false if last_occurrence_date.nil?

    last_occurrence_date < stale_after.ago.to_date
  end

  # Mark as inactive. reason is "user" (paused by the user) or "stale"
  # (no recent occurrence, set by the Cleaner).
  def mark_inactive!(reason: "user")
    update!(status: "inactive", inactive_reason: reason)
  end

  # Mark as active. A resumed row starts again from its next future date
  # instead of back-filling the periods it was inactive for.
  def mark_active!
    reactivate
    roll_next_expected_date_forward
    save!
  end

  # Back to active, forgetting why it was inactive. Does not save.
  def reactivate
    self.status = "active"
    self.inactive_reason = nil
  end

  # Approve a subscription suggestion
  def approve_suggestion!(use_base_currency: false)
    # Set category to "Subscriptions" if available
    subscriptions_category = family.categories.find_by("LOWER(name) LIKE ?", "%subscription%")

    self.category_id = subscriptions_category&.id || category_id

    # Auto-set default_account from inferred_account if not already set
    if default_account_id.blank? && inferred_account_id.present?
      self.default_account_id = inferred_account_id
    end

    # Use detected base currency if requested
    if use_base_currency && detected_base_currency.present? && detected_base_amount.present?
      self.currency = detected_base_currency
      self.amount = detected_base_amount
    end

    # The suggestion may have waited past its date. Start from the next one,
    # rather than generating a transaction for a period nobody confirmed.
    roll_next_expected_date_forward

    approve!
  end

  # Dismiss a subscription suggestion
  def dismiss_suggestion!
    dismiss!
  end

  # Restore a dismissed suggestion
  def restore_suggestion!
    restore!
  end

  # Move next_expected_date to the first billing date after today.
  # Callers decide when this is right (a pattern being refreshed, a
  # subscription resumed or approved); an overdue subscription is otherwise
  # left overdue so GenerateSubscriptionTransactionsJob can generate it.
  def roll_next_expected_date_forward
    return if next_expected_date.present? && next_expected_date > Date.current

    self.next_expected_date = billing_cycle_yearly? ? calculate_future_yearly_date : calculate_future_monthly_date
  end

  # Update based on a new transaction occurrence
  def record_occurrence!(transaction_date, transaction_amount = nil)
    self.last_occurrence_date = transaction_date
    self.next_expected_date = calculate_next_expected_date(transaction_date)

    # Update amount variance for manual recurring transactions BEFORE incrementing count
    if manual? && transaction_amount.present?
      update_amount_variance(transaction_amount)
    end

    self.occurrence_count += 1
    reactivate
    save!
  end

  # Update amount variance tracking based on a new transaction
  def update_amount_variance(transaction_amount)
    # First sample - initialize everything
    if expected_amount_avg.nil?
      self.expected_amount_min = transaction_amount
      self.expected_amount_max = transaction_amount
      self.expected_amount_avg = transaction_amount
      return
    end

    # Update min/max
    self.expected_amount_min = [ expected_amount_min, transaction_amount ].min if expected_amount_min.present?
    self.expected_amount_max = [ expected_amount_max, transaction_amount ].max if expected_amount_max.present?

    # Calculate new average using incremental formula
    # For n samples with average A_n, adding sample x_{n+1} gives:
    # A_{n+1} = A_n + (x_{n+1} - A_n)/(n+1)
    # occurrence_count includes the initial occurrence, so subtract 1 to get variance samples recorded
    n = occurrence_count - 1  # Number of variance samples recorded so far
    self.expected_amount_avg = expected_amount_avg + ((transaction_amount - expected_amount_avg) / (n + 1))
  end

  # Calculate the next expected date based on the last occurrence
  def calculate_next_expected_date(from_date = last_occurrence_date)
    # For yearly subscriptions with expected_month, use the specific month
    if is_subscription? && billing_cycle_yearly? && expected_month.present?
      # Determine the target year: if the expected month is before/equal to from_date's month
      # and from_date's year, use next year; otherwise use from_date's year
      target_year = from_date.year
      if expected_month < from_date.month || (expected_month == from_date.month && expected_day_of_month <= from_date.day)
        target_year += 1
      end

      begin
        Date.new(target_year, expected_month, expected_day_of_month)
      rescue ArgumentError
        # If day doesn't exist in month, use last day of month
        Date.new(target_year, expected_month, 1).end_of_month
      end
    elsif is_subscription? && billing_cycle_yearly?
      # Fallback for yearly without expected_month
      next_period = from_date.next_year
      begin
        Date.new(next_period.year, next_period.month, expected_day_of_month)
      rescue ArgumentError
        next_period.end_of_month
      end
    else
      # Monthly subscriptions
      next_period = from_date.next_month
      begin
        Date.new(next_period.year, next_period.month, expected_day_of_month)
      rescue ArgumentError
        next_period.end_of_month
      end
    end
  end

  # Get the projected transaction for display
  def projected_entry
    return nil unless active?
    return nil unless next_expected_date.future?

    # Use average amount for manual recurring with variance, otherwise use fixed amount
    display_amount = if manual? && expected_amount_avg.present?
      expected_amount_avg
    else
      amount
    end

    OpenStruct.new(
      date: next_expected_date,
      amount: display_amount,
      currency: currency,
      merchant: merchant,
      name: merchant.present? ? merchant.name : name,
      recurring: true,
      projected: true,
      amount_min: expected_amount_min,
      amount_max: expected_amount_max,
      amount_avg: expected_amount_avg,
      has_variance: has_amount_variance?
    )
  end

  # Subscription-specific methods

  # Get the monthly cost for this subscription
  # For yearly subscriptions, divides by 12
  def monthly_cost
    return amount unless is_subscription?
    billing_cycle_yearly? ? (amount / 12) : amount
  end

  # Get the yearly cost for this subscription
  # For monthly subscriptions, multiplies by 12
  def yearly_cost
    return amount unless is_subscription?
    billing_cycle_monthly? ? (amount * 12) : amount
  end

  # Get the logo URL with fallback chain:
  # custom_logo_url -> attached logo -> subscription_service logo -> merchant logo -> nil
  def subscription_logo_url
    return custom_logo_url if custom_logo_url.present?
    return Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached?
    return subscription_service.logo_url if subscription_service.present?
    merchant&.logo_url
  end

  # Display name for the subscription
  def display_name
    merchant.present? ? merchant.name : name
  end

  # Check if this subscription is overdue
  def overdue?
    active? && next_expected_date.present? && next_expected_date < Date.current
  end

  # Check if this subscription is due today
  def due_today?
    active? && next_expected_date == Date.current
  end

  # Check if this subscription can be recorded (due today or overdue)
  def actionable?
    overdue? || due_today?
  end

  # Check if this subscription can auto-generate transactions
  # Only for accounts without active provider connections
  # The single rule GenerateSubscriptionTransactionsJob uses.
  def can_auto_generate?
    default_account.present? && default_account.active? && default_account.unlinked?
  end

  # Get the amount to use for generating transactions
  # Prefers expected_amount_avg for manual recurring with variance
  def amount_for_transaction
    (manual? && expected_amount_avg.present?) ? expected_amount_avg : amount
  end

  # Generate a transaction for the current due date
  # Returns the created Entry, or nil if one already exists for the period
  # or the date is still in the future.
  # The row lock makes the period check and the insert atomic, so a double
  # click and an overlapping cron run cannot both create the transaction.
  def generate_transaction!(for_date: next_expected_date)
    return nil unless default_account.present?
    return nil if for_date.nil? || for_date > Date.current

    entry = nil
    with_lock do
      next if transaction_exists_for_period?(for_date)

      transaction_amount = amount_for_transaction

      sub_money = Money.new(transaction_amount, currency)
      converted = if currency == default_account.currency
        sub_money
      else
        sub_money.exchange_to(default_account.currency, date: for_date, fallback_rate: 1)
      end

      entry = default_account.entries.create!(
        date: for_date,
        amount: converted.amount,
        currency: default_account.currency,
        name: display_name,
        source: "subscription",
        entryable: Transaction.new(
          category: category,
          merchant: merchant,
          recurring_transaction: self
        )
      )

      record_occurrence!(for_date, transaction_amount)
    end

    entry
  end

  # Generate all due/overdue transactions up to today
  # Returns array of created entries
  def generate_overdue_transactions!
    return [] unless default_account.present?
    return [] unless actionable?

    entries = []
    current_date = next_expected_date

    while current_date <= Date.current
      entry = generate_transaction!(for_date: current_date)
      entries << entry if entry

      # Recalculate next date for the loop
      current_date = calculate_next_expected_date(current_date)
    end

    entries
  end

  # Check if a transaction already exists for this period
  def transaction_exists_for_period?(date)
    return false unless default_account.present?

    date_range = if billing_cycle_yearly?
      date.beginning_of_year..date.end_of_year
    else
      date.beginning_of_month..date.end_of_month
    end

    default_account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where("transactions.recurring_transaction_id = ?", id)
      .where(date: date_range)
      .exists?
  end

  private
    def monetizable_currency
      currency
    end

    # Billing cycle from the transaction history and the Subscriptions
    # category when there is one. A yearly cycle needs its billing month.
    def assign_detected_subscription_attributes
      matching_entries = self.class.find_matching_transaction_entries(
        family: family,
        merchant_id: merchant_id,
        name: name,
        currency: currency,
        expected_day: expected_day_of_month,
        lookback_months: 24
      )
      cycle = SubscriptionDetector.detect_billing_cycle(matching_entries.map(&:date))

      assign_attributes(
        billing_cycle: cycle,
        category_id: family.categories.find_by("LOWER(name) LIKE ?", "%subscription%")&.id || category_id
      )
      if billing_cycle_yearly? && expected_month.blank?
        self.expected_month = matching_entries.map(&:date).max&.month || last_occurrence_date&.month || Date.current.month
      end
    end

    def write_legacy_subscription_columns
      self.is_subscription = subscription?
      self.suggestion_status = suggested? ? "suggested" : (dismissed? ? "dismissed" : nil)
    end

    def calculate_future_yearly_date
      today = Date.current
      target_month = expected_month || last_occurrence_date&.month || today.month
      target_day = expected_day_of_month
      target_year = today.year

      loop do
        target_date = begin
          Date.new(target_year, target_month, target_day)
        rescue ArgumentError
          Date.new(target_year, target_month, 1).end_of_month
        end

        return target_date if target_date > today
        target_year += 1
      end
    end

    def calculate_future_monthly_date
      today = Date.current
      target_date = today.beginning_of_month

      loop do
        next_date = begin
          Date.new(target_date.year, target_date.month, expected_day_of_month)
        rescue ArgumentError
          target_date.end_of_month
        end

        return next_date if next_date > today
        target_date = target_date.next_month
      end
    end
end
