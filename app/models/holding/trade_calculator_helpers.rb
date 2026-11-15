# Shared by Holding::ForwardCalculator and Holding::ReverseCalculator. The including
# class exposes `portfolio_cache`.
module Holding::TradeCalculatorHelpers
  private
    # Feeds one trade into its security's cost-basis tracker and returns how the trade
    # touches the "unknown because transferred in" mark:
    #   :transfer_in for units moved in from elsewhere. They were acquired at a price
    #     nothing here knows, so the whole position's basis is unknown while they are
    #     held. They do not enter the tracker.
    #   nil for everything else. A buy raises the basis, and a sale or a transfer out
    #     relieves units at the running average.
    def apply_trade_to_tracker(tracker, trade_entry)
      trade = trade_entry.entryable
      return :transfer_in if trade.transfer_movement? && trade.qty.positive?

      tracker.apply(trade.qty.positive? ? converted_trade_price(trade_entry) : nil, trade.qty)
      nil
    end

    # The trade price in the account currency at the trade's own date (nearest-rate
    # rule), or nil when the pair has no rate at all. Never a rate of 1.
    def converted_trade_price(trade_entry)
      portfolio_cache.trade_price_in_account_currency(trade_entry.entryable, trade_entry.date)
    end
end
