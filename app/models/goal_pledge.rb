# "I just put X into this account for this goal" (w2-goals goal-pledges, ported from
# upstream). The pledge stays open for a week and is kept when the money shows up:
# GoalPledge::Reconciler matches it against an inflow transaction or a balance update
# on the account.
#
# Status is an AASM state machine (the fork keeps its records' lifecycles in AASM):
#   open -> matched    the money arrived (match)
#   open -> cancelled  the user took it back (cancel)
#   open -> expired    the week passed, StaleWorkReaperJob (expire)
#   matched -> open    the transaction that kept it was deleted (release); straight to
#                      expired when the window has passed meanwhile
#
# Fork changes to the matching (all accounts here are manual):
# - kind is "manual_save" for a cash account and "transfer" for an investment or crypto
#   account (Account#default_pledge_kind). An inflow transaction keeps either kind,
#   because a manual account records its deposits as transactions too. A balance update
#   keeps only a manual_save pledge: on an investment account a rise may be the market.
class GoalPledge < ApplicationRecord
  include AASM, Monetizable

  KINDS = %w[transfer manual_save].freeze
  STATUSES = %w[open matched cancelled expired].freeze

  DEFAULT_WINDOW_DAYS = 7
  EXTEND_DAYS = 7
  MATCH_DATE_TOLERANCE_DAYS = 5
  MATCH_AMOUNT_TOLERANCE_ABSOLUTE = BigDecimal("0.50")
  MATCH_AMOUNT_TOLERANCE_RATIO = BigDecimal("0.01")

  class NotOpenError < StandardError; end
  # The transaction already keeps another pledge: a known race, not a failure
  class AlreadyClaimedError < StandardError; end

  belongs_to :goal
  belongs_to :account
  belongs_to :matched_transaction, class_name: "Transaction", optional: true

  delegate :family, to: :goal

  monetize :amount

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :expires_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  # On create only: unlinking the account later must not make an existing pledge
  # impossible to expire, release or cancel
  validate :account_must_be_linked_to_goal, on: :create
  validate :currency_matches_goal
  validate :no_duplicate_open_pledge, on: :create

  before_validation :assign_defaults, on: :create
  before_destroy :clear_matched_transaction_extra

  # Open and inside its window: what the goal page and the reconciler look at
  scope :pending, -> { where(status: "open").where("goal_pledges.expires_at >= ?", Time.current) }
  # Open past its window: StaleWorkReaperJob expires these
  scope :stale, -> { where(status: "open").where("goal_pledges.expires_at < ?", Time.current) }
  scope :reverse_chronological, -> { order(created_at: :desc) }

  aasm column: :status, whiny_persistence: true, create_scopes: false do
    state :open, initial: true
    state :matched
    state :cancelled
    state :expired

    event :match do
      transitions from: :open, to: :matched
    end

    event :cancel do
      transitions from: :open, to: :cancelled
    end

    event :expire do
      transitions from: :open, to: :expired
    end

    # The transition callback runs before the state is saved, so the cleared match is
    # saved with it (an event-level `before` would run even when nothing can fire)
    event :release do
      transitions from: :matched, to: :expired, guard: :past_expiry?, after: :clear_match
      transitions from: :matched, to: :open, after: :clear_match
    end
  end

  def kind_transfer? = kind == "transfer"
  def kind_manual_save? = kind == "manual_save"

  def past_expiry?
    expires_at.present? && expires_at < Time.current
  end

  # Whether `entry` keeps this pledge. A transaction keeps it with its inflow (Sure
  # stores an inflow as a negative amount); a valuation with `valuation_delta`, the
  # balance change it recorded (Account::ReconciliationManager knows the prior balance).
  def matches?(entry, valuation_delta: nil)
    if entry.respond_to?(:entryable) && entry.entryable.is_a?(Valuation)
      matches_balance_change?(account_id: entry.account_id, delta: valuation_delta, currency: entry.currency, date: entry.date)
    else
      return false if entry.respond_to?(:excluded) && entry.excluded

      matches_contribution?(account_id: entry.account_id, amount: -entry.amount.to_d, currency: entry.currency, date: entry.date)
    end
  end

  # A balance that rose by `delta` on `date`. Never on an investment or crypto account,
  # where a rise may be a market move, and only for a manual_save pledge.
  def matches_balance_change?(account_id:, delta:, currency:, date:)
    return false unless kind_manual_save?
    return false if delta.nil? || account&.balance_type == :investment

    matches_contribution?(account_id: account_id, amount: delta.to_d, currency: currency, date: date)
  end

  # `amount` is the money that came in (positive), in `currency`. Within the date window
  # (5 days either side of the pledge, or up to its expiry once extended) and within
  # 0.50 or 1% of the pledge after conversion to goal currency by the nearest-rate rule.
  # No rate: no match.
  def matches_contribution?(account_id:, amount:, currency:, date:)
    return false unless open?
    return false unless account_id == self.account_id
    return false unless amount.to_d.positive?
    return false unless within_date_window?(date.to_date)

    contribution = goal.convert_money!(Money.new(amount.to_d, currency.presence || account.currency), date: date.to_date).amount
    diff = (contribution - self.amount.to_d).abs

    diff <= MATCH_AMOUNT_TOLERANCE_ABSOLUTE || (diff / self.amount.to_d) <= MATCH_AMOUNT_TOLERANCE_RATIO
  rescue Money::ConversionError
    false
  end

  # Kept by a transaction: the transaction is stamped with extra["goal"]["pledge_id"]
  # (beside the fork's exchange_rate and replaced_subscription_charge keys) and the
  # pledge points back at it. Both locked, so two workers cannot claim one transaction.
  def resolve_with!(transaction)
    with_lock do
      raise NotOpenError, "Pledge no longer open" unless open?

      transaction.with_lock do
        claimed = transaction.extra&.dig("goal", "pledge_id")
        if claimed.present? && claimed != id
          raise AlreadyClaimedError, "Transaction #{transaction.id} already keeps pledge #{claimed}"
        end

        extra = (transaction.extra || {}).deep_dup
        extra["goal"] = (extra["goal"] || {}).merge("pledge_id" => id)
        transaction.update!(extra: extra)

        self.matched_transaction = transaction
        self.matched_on = transaction.entry&.date
        match!
      end
    end
  end

  # Kept by a balance update: there is no transaction to stamp
  def resolve_with_valuation!(entry)
    with_lock do
      raise NotOpenError, "Pledge no longer open" unless open?

      self.matched_on = entry.date
      match!
    end
  end

  def extend!(days: EXTEND_DAYS)
    raise NotOpenError, "Only open pledges can be extended" unless open?

    update!(expires_at: expires_at + days.days)
  end

  def days_left
    return 0 unless open?

    [ ((expires_at - Time.current) / 1.day).ceil, 0 ].max
  end

  private
    def assign_defaults
      self.kind ||= account&.default_pledge_kind || "transfer"
      self.expires_at ||= Time.current + DEFAULT_WINDOW_DAYS.days
      self.currency ||= goal&.currency
    end

    def within_date_window?(date)
      anchor = (created_at || Time.current).to_date
      earliest = anchor - MATCH_DATE_TOLERANCE_DAYS.days
      latest = [ anchor + MATCH_DATE_TOLERANCE_DAYS.days, expires_at.to_date ].max
      date.between?(earliest, latest)
    end

    def clear_match
      unstamp_matched_transaction!
      self.matched_transaction_id = nil
      self.matched_on = nil
    end

    def clear_matched_transaction_extra
      unstamp_matched_transaction!
    end

    # Takes this pledge's id off the transaction that kept it, and nothing else
    def unstamp_matched_transaction!
      return if matched_transaction_id.blank?

      txn = Transaction.find_by(id: matched_transaction_id)
      return if txn.nil? || txn.destroyed? || txn.extra&.dig("goal", "pledge_id") != id

      extra = txn.extra.deep_dup
      extra["goal"].delete("pledge_id")
      extra.delete("goal") if extra["goal"].empty?
      txn.update_columns(extra: extra)
    end

    def account_must_be_linked_to_goal
      return if goal.nil? || account.nil?
      return if goal.goal_accounts.any? { |link| link.account_id == account_id && !link.marked_for_destruction? }

      errors.add(:account, :must_be_linked_to_goal)
    end

    def currency_matches_goal
      return if goal.nil? || currency.blank? || currency == goal.currency

      errors.add(:currency, :must_match_goal)
    end

    # A double click would otherwise leave two identical banners, one of them to expire
    def no_duplicate_open_pledge
      return unless goal_id && account_id && amount && open?

      duplicate = GoalPledge.pending.where(goal_id: goal_id, account_id: account_id, amount: amount).exists?
      errors.add(:base, :duplicate_open_pledge) if duplicate
    end
end
