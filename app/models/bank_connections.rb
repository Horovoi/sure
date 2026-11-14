# Bank and crypto connection providers (Plaid, Lunch Flow, Enable Banking, CoinStats,
# Coinbase). Off unless BANK_CONNECTIONS_ENABLED is set; this instance uses none of them.
module BankConnections
  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("BANK_CONNECTIONS_ENABLED", "false"))
  end
end
