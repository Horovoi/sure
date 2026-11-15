class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  def initialize(account)
    @account = account
    # Weighted-average cost basis per security. Sells relieve it, so the figure stays
    # right after a position is sold off and bought again.
    @cost_basis_trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
    # Securities whose position holds units transferred in from elsewhere. Those were
    # acquired at a price nothing here knows, and averaging the purchases alone would
    # apply their price to units that never cost it.
    @transferred_security_ids = Set.new
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        next_portfolio = apply_trades(current_portfolio, trades)
        holdings.concat(build_holdings(next_portfolio, date))
        current_portfolio = next_portfolio
      end

      portfolio_cache.report_unconverted(source: "Holding::ForwardCalculator")
      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account)
    end

    def empty_portfolio
      securities = portfolio_cache.get_securities
      securities.each_with_object({}) { |security, hash| hash[security.id] = 0 }
    end

    def generate_starting_portfolio
      empty_portfolio
    end

    def build_holdings(portfolio, date, price_source: nil)
      portfolio.map do |security_id, qty|
        price = portfolio_cache.get_price(security_id, date, source: price_source)

        if price.nil?
          next
        end

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id),
          cost_basis_unknown: cost_basis_unknown?(security_id)
        )
      end.compact
    end

    # Applies the day's trades in order and returns the closing portfolio. The running
    # position is tracked trade by trade, so the "transferred in" mark is released the
    # moment the position reaches zero, even when a same-day sell-off and repurchase net
    # back to a positive quantity at the end of the day.
    def apply_trades(opening_portfolio, trade_entries)
      portfolio = opening_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_qty = portfolio[security_id] || 0

        if apply_trade_to_tracker(@cost_basis_trackers[security_id], trade_entry) == :transfer_in
          @transferred_security_ids << security_id
        end

        portfolio[security_id] = previous_qty + trade.qty

        # Only a real downward crossing through zero: a position that was not positive
        # never held these units, so opening and closing must not collapse onto one trade
        @transferred_security_ids.delete(security_id) if previous_qty.positive? && portfolio[security_id] <= 0
      end

      portfolio
    end

    # The current cost basis for a security, or nil when nothing is held, the position
    # holds transferred-in units, or a held purchase has no exchange rate.
    def cost_basis_for(security_id)
      return nil if @transferred_security_ids.include?(security_id)

      @cost_basis_trackers[security_id].average_cost
    end

    # Unknown is not the same as nil: nil means nothing was worked out (the materializer
    # leaves an earlier figure standing), unknown means no figure can be known now, so a
    # stale calculated one has to go.
    def cost_basis_unknown?(security_id)
      @transferred_security_ids.include?(security_id) || @cost_basis_trackers[security_id].unknown?
    end
end
