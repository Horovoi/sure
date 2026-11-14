# One switch for the bank and crypto connection providers: Plaid, Lunch Flow,
# Enable Banking, CoinStats and Coinbase.
#
# Off by default. While it is off, the app hides every way to connect, link or
# manage those providers, their controllers and webhooks respond 404, and their
# scheduled syncs are skipped. Existing provider records are left untouched.
#
# Market data (Twelve Data, Yahoo Finance, NBU) and LLM providers are not
# affected by this switch.
#
# Turn it on with BANK_CONNECTIONS_ENABLED=true.
module BankConnections
  ENV_KEY = "BANK_CONNECTIONS_ENABLED".freeze

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV[ENV_KEY]) == true
  end
end
