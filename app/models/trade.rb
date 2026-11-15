class Trade < ApplicationRecord
  include Entryable, Monetizable

  monetize :price

  belongs_to :security
  belongs_to :category, optional: true

  # Use the same activity labels as Transaction
  ACTIVITY_LABELS = Transaction::ACTIVITY_LABELS.dup.freeze

  # Moving an asset between places you own is not an acquisition, so it must not set a
  # cost basis, and moving it out is not a sale. One label, not the wider
  # Transaction::INTERNAL_MOVEMENT_LABELS: "Exchange" on a security can be a disposal, and
  # nothing has shown a sweep landing on a security. Holding and the calculators read it.
  TRANSFER_LABEL = "Transfer".freeze

  validates :qty, presence: true
  validates :price, :currency, presence: true
  validates :investment_activity_label, inclusion: { in: ACTIVITY_LABELS }, allow_nil: true

  # Trade types for categorization
  def buy?
    qty.positive?
  end

  def sell?
    qty.negative?
  end

  # Units moved in from, or out to, a place the owner also holds. It looks exactly like a
  # buy or a sale (same sign, same shape), and only the label tells them apart.
  def transfer_movement?
    investment_activity_label == TRANSFER_LABEL
  end

  class << self
    def build_name(type, qty, ticker)
      prefix = type == "buy" ? "Buy" : "Sell"
      "#{prefix} #{qty.to_d.abs} shares of #{ticker}"
    end
  end

  # The current price is in the security's price currency and the cost in the trade's, so
  # the value converts into the trade's currency first (nearest-rate rule). nil when the
  # pair has no rate at all.
  def unrealized_gain_loss
    return nil if qty.negative?
    current_price = security.current_price
    return nil if current_price.nil?

    current_value = ExchangeRate.convert_or_leave_out(
      current_price * qty.abs, to: currency, source: "Trade#unrealized_gain_loss", family: entry&.account&.family
    )
    return nil if current_value.nil?

    cost_basis = price_money * qty.abs

    Trend.new(current: current_value, previous: cost_basis)
  end

  # Set by callers that list many disposals, so the proceeds conversion below reads one
  # preloaded set instead of a query per foreign disposal. Keyed [from, to, date] with the
  # day's stored rate. A missing key is not "no rate": the conversion then applies the
  # nearest-rate rule itself.
  def preloaded_exchange_rates=(value)
    @preloaded_exchange_rates = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
    @realized_gain_unconvertible = false
  end

  # One query for the day's rates a set of disposals can need, instead of one per disposal.
  # The product of the date and currency sets is a superset of the pairs wanted, which is
  # cheaper to fetch than to describe pair by pair in SQL.
  def self.preload_exchange_rates(trades)
    return if trades.empty?

    wanted = trades.flat_map do |trade|
      from = trade.currency
      next [] if from.blank?

      # Both currencies the basis can be carried in: the account's (the usual case) and the
      # preloaded holding's own where it differs
      [ trade.entry.account.currency, trade.preloaded_basis_currency ]
        .compact_blank
        .uniq
        .reject { |to| to == from }
        .map { |to| [ from, to, trade.entry.date ] }
    end

    rates = if wanted.empty?
      {}
    else
      ExchangeRate
        .where(from_currency: wanted.map(&:first).uniq, to_currency: wanted.map(&:second).uniq, date: wanted.map(&:third).uniq)
        .where("exchange_rates.rate > 0")
        .to_h { |rate| [ [ rate.from_currency, rate.to_currency, rate.date ], rate.rate ] }
    end

    trades.each { |trade| trade.preloaded_exchange_rates = rates }
  end

  # The currency this disposal's basis is carried in, where it can be answered without a
  # query: Holding#avg_cost is Money in the holding's own currency. nil when holdings were
  # not preloaded, so the preloader never issues the queries it exists to avoid.
  def preloaded_basis_currency
    return nil unless defined?(@preloaded_holdings)

    basis_holding&.currency
  end

  # Calculates realized gain/loss for sell trades based on avg_cost at time of sale.
  # The figure is in the currency the position's basis is carried in.
  # Returns nil for buy trades, when cost basis cannot be determined, or when the
  # proceeds have no exchange rate into the basis currency (realized_gain_unconvertible?)
  def realized_gain_loss
    return @realized_gain_loss if defined?(@realized_gain_loss)

    @realized_gain_unconvertible = false
    @realized_gain_loss = calculate_realized_gain_loss
  end

  # True when #realized_gain_loss is nil only because the proceeds' currency has no
  # exchange rate into the basis currency at all, as opposed to a buy or an unknown cost
  # basis. A caller summing gains counts these as left out.
  def realized_gain_unconvertible?
    realized_gain_loss
    @realized_gain_unconvertible
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end

  private

    # The position the disposal is measured against: the latest snapshot for this security
    # on or before the disposal's date. Uses preloaded holdings when the caller set them
    # (set by the reports controller to avoid N+1), and treats a defined-but-empty preload
    # as authoritative. select + max_by, so the answer does not depend on array order.
    # Not memoised: realized_gain_loss already is.
    def basis_holding
      if defined?(@preloaded_holdings)
        (@preloaded_holdings || [])
          .select { |h| h.security_id == security_id && h.date <= entry.date }
          .max_by(&:date)
      else
        entry.account.holdings
          .where(security_id: security_id)
          .where("date <= ?", entry.date)
          .order(date: :desc)
          .first
      end
    end

    def calculate_realized_gain_loss
      return nil unless sell?
      # Units sent to another account you own were not sold: comparing their basis with
      # the day's price would book a gain nobody made.
      return nil if transfer_movement?

      holding = basis_holding

      return nil unless holding&.avg_cost

      cost_basis = holding.avg_cost * qty.abs
      sale_proceeds = converted_to_basis_currency(price_money * qty.abs, cost_basis.currency)

      # No rate means the gain is unknown, not zero and not the figure a rate of 1 would give
      if sale_proceeds.nil?
        @realized_gain_unconvertible = true
        return nil
      end

      Trend.new(current: sale_proceeds, previous: cost_basis)
    end

    # The proceeds are priced in the trade's currency and the basis is carried in the
    # holding's. They are converted into the basis currency at the sale's own date before
    # the subtraction (it used to subtract the bare numbers and label the difference with
    # the trade currency). The day's preloaded rate when there is one, else the
    # nearest-rate rule; nil with no rate at all.
    def converted_to_basis_currency(proceeds, basis_currency)
      from = proceeds.currency.iso_code
      to = basis_currency.iso_code
      return proceeds if from == to

      rate = preloaded_rate(from, to)
      return Money.new(proceeds.amount * rate, to) if ExchangeRate.valid_rate?(rate)

      ExchangeRate.convert_or_leave_out(
        proceeds, to: to, date: entry.date, source: "Trade#realized_gain_loss", family: entry.account.family
      )
    end

    def preloaded_rate(from, to)
      return nil unless defined?(@preloaded_exchange_rates)

      (@preloaded_exchange_rates || {})[[ from, to, entry.date ]]
    end
end
