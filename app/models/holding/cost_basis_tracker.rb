# Weighted-average cost basis of one security, fed its trades in chronological order.
#
# A buy adds its cost and quantity. A sell relieves quantity at the running average, so
# the per-share average stays the same, and once the position is fully closed the
# tracker starts again: a later repurchase is not averaged against lots already sold.
#
# Prices are in the account currency (the caller converts at the trade's own date). A
# buy whose price could not be converted (nil: no rate at all) makes the average
# unknown while those units are held. It is never counted at a rate of 1, and it is
# released when the position closes.
class Holding::CostBasisTracker
  def initialize
    reset
  end

  # Applies a trade by its signed quantity: positive is a buy, negative a sell. The
  # price is read only for a buy.
  def apply(price, qty)
    return if qty.nil?

    qty = qty.to_d
    return if qty.zero?

    qty.positive? ? buy(price, qty) : sell(qty)
  end

  def buy(price, qty)
    qty = qty&.to_d
    return if qty.nil? || !qty.positive?

    if price.nil?
      @unknown = true
    else
      @total_cost += price.to_d * qty
    end

    @total_qty += qty
  end

  def sell(qty)
    qty = qty&.to_d
    return if qty.nil? || qty.zero? || @total_qty.zero?

    # Never relieve more than is held, so an over-sell cannot drive the basis negative.
    relieved_qty = [ qty.abs, @total_qty ].min
    @total_cost -= @total_cost * relieved_qty / @total_qty
    @total_qty -= relieved_qty

    # BigDecimal keeps the arithmetic exact, so a full liquidation lands on zero and resets
    reset if @total_qty <= 0
  end

  # The weighted-average cost per unit, or nil when nothing is held or a held purchase
  # has no exchange rate into the account currency.
  def average_cost
    return nil if @unknown || @total_qty.zero?

    @total_cost / @total_qty
  end

  # True while a held purchase could not be converted into the account currency.
  def unknown?
    @unknown
  end

  private
    def reset
      @total_cost = BigDecimal("0")
      @total_qty = BigDecimal("0")
      @unknown = false
    end
end
