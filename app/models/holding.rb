class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  # Cost basis source priority (higher = takes precedence)
  COST_BASIS_SOURCE_PRIORITY = {
    nil => 0,
    "provider" => 1,
    "calculated" => 2,
    "manual" => 3
  }.freeze

  COST_BASIS_SOURCES = %w[manual calculated provider].freeze

  belongs_to :account
  belongs_to :security
  belongs_to :account_provider, optional: true

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :cost_basis_source, inclusion: { in: COST_BASIS_SOURCES }, allow_nil: true

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }
  scope :with_locked_cost_basis, -> { where(cost_basis_locked: true) }
  scope :with_unlocked_cost_basis, -> { where(cost_basis_locked: false) }

  delegate :ticker, to: :security

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    account.balance.zero? ? 1 : amount / account.balance * 100
  end

  # Returns average cost per share, or nil if unknown.
  #
  # Uses pre-computed cost_basis if available (set during materialization),
  # otherwise falls back to calculating from trades. Returns nil when cost
  # basis cannot be determined (no trades and no provider cost_basis).
  def avg_cost
    # Use stored cost_basis if available (eliminates N+1 queries)
    # - If locked (user-set), trust the value even if 0 (valid for airdrops)
    # - Otherwise require positive since providers sometimes return 0 when unknown
    if cost_basis.present?
      if cost_basis_locked? || cost_basis.positive?
        return Money.new(cost_basis, currency)
      end
    end

    # Fallback to calculation for holdings without pre-computed cost_basis
    calculate_avg_cost
  end

  def trend
    @trend ||= calculate_trend
  end

  # Day change based on previous holding snapshot (same account/security/currency)
  # Returns a Trend struct similar to other trend usages or nil if no prior snapshot.
  def day_change
    # Memoize even when nil to avoid repeated queries during a request lifecycle
    return @day_change if instance_variable_defined?(:@day_change)

    return (@day_change = nil) unless amount_money

    prev = account.holdings
                 .where(security_id: security_id, currency: currency)
                 .where("date < ?", date)
                 .order(date: :desc)
                 .first

    @day_change = prev&.amount_money ? Trend.new(current: amount_money, previous: prev.amount_money) : nil
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end

  # Returns the priority level for the current source (higher = better)
  def cost_basis_source_priority
    COST_BASIS_SOURCE_PRIORITY[cost_basis_source] || 0
  end

  # Check if this holding's cost_basis can be overwritten by the given source
  def cost_basis_replaceable_by?(new_source)
    return false if cost_basis_locked?

    new_priority = COST_BASIS_SOURCE_PRIORITY[new_source] || 0

    # Special case: when user unlocks a manual cost_basis, they're opting into
    # recalculation. Allow only "calculated" source to replace it (from trades).
    # This is the whole point of the unlock action.
    if cost_basis_source == "manual"
      return new_source == "calculated"
    end

    new_priority > cost_basis_source_priority
  end

  # Set cost_basis from user input (locks the value).
  #
  # Holdings are stored one row per day, but a manual cost basis belongs to the position: it
  # applies to this row and every later row of the same security. The materializer carries it
  # forward to rows it creates later.
  def set_manual_cost_basis!(value)
    transaction do
      update!(
        cost_basis: value,
        cost_basis_source: "manual",
        cost_basis_locked: true
      )

      later_rows_of_position.update_all(
        cost_basis: value,
        cost_basis_source: "manual",
        cost_basis_locked: true,
        updated_at: Time.current
      )
    end
  end

  # Unlock cost_basis to allow provider/calculated updates, for the whole position
  # (otherwise an older locked row would be carried forward again).
  def unlock_cost_basis!
    transaction do
      update!(cost_basis_locked: false)
      account.holdings.where(security_id: security_id, cost_basis_locked: true).update_all(cost_basis_locked: false, updated_at: Time.current)
    end
  end

  # Check if cost_basis is known (has a source and positive value)
  def cost_basis_known?
    cost_basis.present? && cost_basis.positive? && cost_basis_source.present?
  end

  # Human-readable source label for UI display
  def cost_basis_source_label
    return nil unless cost_basis_source.present?

    I18n.t("holdings.cost_basis_sources.#{cost_basis_source}")
  end

  private
    def later_rows_of_position
      account.holdings.where(security_id: security_id, currency: currency).where("date > ?", date)
    end

    def calculate_trend
      return nil unless amount_money
      return nil if avg_cost.nil? # Can't calculate trend without cost basis (0 is valid for airdrops)

      start_amount = qty * avg_cost

      Trend.new \
        current: amount_money,
        previous: start_amount
    end

    # Calculates weighted average cost from buy trades, each converted into the holding's
    # currency at the nearest stored rate of its day.
    # Returns nil if no trades exist, or when a trade's currency has no rate at all: the
    # cost basis is unknown then, never a figure with that purchase counted at 1.
    def calculate_avg_cost
      trades = account.trades
        .with_entry
        .where(security_id: security.id)
        .where("trades.qty > 0 AND entries.date <= ?", date)

      rate = ExchangeRate.rate_sql(
        from: "trades.currency",
        to: ActiveRecord::Base.connection.quote(currency),
        on: "entries.date"
      )

      total_cost, total_qty, rate_missing = trades.pick(
        Arel.sql("SUM(trades.price * trades.qty * #{rate})"),
        Arel.sql("SUM(trades.qty)"),
        Arel.sql("COUNT(*) FILTER (WHERE #{rate} IS NULL)")
      )

      # Return nil when no trades exist - cost basis is genuinely unknown
      # Previously this fell back to current market price, which was misleading
      return nil unless total_qty && total_qty > 0
      return nil if rate_missing.to_i.positive?

      Money.new(total_cost / total_qty, currency)
    end
end
