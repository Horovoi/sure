module Holding::Gapfillable
  extend ActiveSupport::Concern

  class_methods do
    def gapfill(holdings)
      filled_holdings = []

      holdings.group_by { |h| h.security_id }.each do |security_id, security_holdings|
        next if security_holdings.empty?

        # One lookup per day instead of a scan of the security's whole history. The first
        # holding of a date wins, as the scan's find did.
        by_date = security_holdings.each_with_object({}) { |h, map| map[h.date] ||= h }
        previous_holding = security_holdings.min_by(&:date)

        previous_holding.date.upto(Date.current) do |date|
          holding = by_date[date]

          if holding
            filled_holdings << holding
            previous_holding = holding
          else
            # Create a new holding based on the previous day's data.
            # Read the ids, not the associations: a Holding::HoldingData has no loaded
            # association, and a Holding record's would be one query per filled day
            filled_holdings << Holding::HoldingData.new(
              account_id: previous_holding.account_id,
              security_id: previous_holding.security_id,
              date: date,
              qty: previous_holding.qty,
              price: previous_holding.price,
              currency: previous_holding.currency,
              amount: previous_holding.amount,
              cost_basis: previous_holding.cost_basis,
              cost_basis_unknown: previous_holding.try(:cost_basis_unknown)
            )
          end
        end
      end

      filled_holdings
    end
  end
end
