# Groups uncategorized transactions for the categorize wizard, so one pick categorizes
# a whole group. Transaction::Grouper.strategy names the grouping in use.
class Transaction::Grouper
  # grouping_key:     the text a "name contains" rule for the group starts from
  # merchant:         the group's merchant, or nil for a group of names
  # transaction_type: "income" or "expense", as the rule's transaction type condition reads it
  Group = Data.define(:grouping_key, :display_name, :entries, :merchant, :transaction_type) do
    def merchant_group?
      merchant.present?
    end
  end

  # The absolute sum of `entries` in `currency`, each converted at the nearest stored rate.
  # An amount with no rate at all is left out (never converted at 1).
  def self.total_money(entries, currency)
    rates = ExchangeRate.rates_for(entries.map(&:currency).uniq, to: currency)
    sum = entries.sum(0.to_d) do |entry|
      rate = rates[entry.currency]
      rate ? entry.amount.abs * rate.to_d : 0.to_d
    end

    Money.new(sum, currency)
  end

  # Income as Rule::ConditionFilter::TransactionType reads it: an inflow that is not an
  # investment contribution (a contribution is an expense whatever its sign).
  INCOME_SQL = "(entries.amount < 0 AND transactions.kind <> 'investment_contribution')".freeze

  def self.strategy
    Transaction::Grouper::ByMerchantOrName
  end

  # entries: an entries relation the caller has scoped to the family.
  # Returns up to `limit` groups, the largest first, after skipping `offset` groups.
  def self.call(entries, limit: 20, offset: 0)
    raise NotImplementedError, "#{name} must implement .call"
  end
end
