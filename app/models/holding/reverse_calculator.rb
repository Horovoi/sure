class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account, :portfolio_snapshot

  def initialize(account, portfolio_snapshot:)
    @account = account
    @portfolio_snapshot = portfolio_snapshot
  end

  def calculate
    Rails.logger.tagged("Holding::ReverseCalculator") do
      precompute_cost_basis
      holdings = calculate_holdings
      portfolio_cache.report_unconverted(source: "Holding::ReverseCalculator")
      Holding.gapfill(holdings)
    end
  end

  private
    # Reverse calculators will use the existing holdings as a source of security ids and prices
    # since it is common for a provider to supply "current day" holdings but not all the historical
    # trades that make up those holdings.
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, use_holdings: true)
    end

    def calculate_holdings
      # Start with the portfolio snapshot passed in from the materializer
      current_portfolio = portfolio_snapshot.to_h
      previous_portfolio = {}

      holdings = []

      Date.current.downto(account.start_date).each do |date|
        today_trades = portfolio_cache.get_trades(date: date)
        previous_portfolio = transform_portfolio(current_portfolio, today_trades, direction: :reverse)

        # If current day, always use holding prices (since that's what Plaid gives us).  For historical values, use market data (since Plaid doesn't supply historical prices)
        holdings.concat(build_holdings(current_portfolio, date, price_source: date == Date.current ? "holding" : nil))
        current_portfolio = previous_portfolio
      end

      holdings
    end

    def transform_portfolio(previous_portfolio, trade_entries, direction: :forward)
      new_quantities = previous_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        qty_change = trade.qty
        qty_change = qty_change * -1 if direction == :reverse
        new_quantities[security_id] = (new_quantities[security_id] || 0) + qty_change
      end

      new_quantities
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
          cost_basis: cost_basis_for(security_id, date),
          cost_basis_unknown: cost_basis_unknown?(security_id, date)
        )
      end.compact
    end

    # Walks every trade forward once and records, per security, the basis after each
    # trade ([date, average, unknown], in trade order) and the spans [start, stop) during
    # which the position holds units transferred in. stop is nil while a span is still
    # open at the last trade.
    def precompute_cost_basis
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      @unknown_spans = Hash.new { |h, k| h[k] = [] }
      trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
      open_unknown_start = {}

      # Already chronological (date, then created_at, then id). The tracker is order
      # sensitive once sells relieve it, so a re-sort by date alone could swap a same-day
      # sell and repurchase.
      trades = portfolio_cache.get_trades

      # A reverse-synced account can hold shares before its first imported trade. Seed
      # each running position from the snapshot minus the net imported trades, so "back at
      # zero" is the real position, not just the trades this app happens to have.
      net_qty = Hash.new(0)
      trades.each { |trade_entry| net_qty[trade_entry.entryable.security_id] += trade_entry.entryable.qty }
      snapshot = portfolio_snapshot.to_h
      positions = Hash.new(0)
      net_qty.each_key { |security_id| positions[security_id] = (snapshot[security_id] || 0) - net_qty[security_id] }

      trades.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        tracker = trackers[security_id]
        previous_position = positions[security_id]
        positions[security_id] += trade.qty

        if apply_trade_to_tracker(tracker, trade_entry) == :transfer_in
          open_unknown_start[security_id] ||= trade_entry.date
        else
          # Recorded after every trade, nil once fully sold, so a sold-out span has no
          # basis instead of the last figure carried forward
          @cost_basis_snapshots[security_id] << [ trade_entry.date, tracker.average_cost, tracker.unknown? ]
        end

        # Close an open span only on a real downward crossing through zero. A gapped
        # import can reconstruct a negative baseline, and that position never held the
        # transferred units.
        if open_unknown_start[security_id] && previous_position.positive? && positions[security_id] <= 0
          @unknown_spans[security_id] << [ open_unknown_start[security_id], trade_entry.date ]
          open_unknown_start.delete(security_id)
        end
      end

      open_unknown_start.each { |security_id, start| @unknown_spans[security_id] << [ start, nil ] }
    end

    def transferred_by?(security_id, date)
      @unknown_spans[security_id].any? { |start, stop| start <= date && (stop.nil? || date < stop) }
    end

    def cost_basis_for(security_id, date)
      return nil if transferred_by?(security_id, date)

      snapshot_on(security_id, date)&.second
    end

    # Unknown, not just nil: the position holds transferred-in units, or a held purchase
    # has no exchange rate. The materializer clears a stale calculated figure for these.
    def cost_basis_unknown?(security_id, date)
      transferred_by?(security_id, date) || snapshot_on(security_id, date)&.third == true
    end

    # The last snapshot on or before the date, by binary search over the trade-ordered list
    def snapshot_on(security_id, date)
      snapshots = @cost_basis_snapshots[security_id]
      index = snapshots.bsearch_index { |snapshot| snapshot.first > date }
      index = snapshots.size if index.nil?
      index.zero? ? nil : snapshots[index - 1]
    end
end
