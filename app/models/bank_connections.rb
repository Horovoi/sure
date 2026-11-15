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

  # Every Family association that holds provider connection items, in sync order.
  # The family syncer and the family reset both walk this list, so a new provider
  # is added here once. A test checks it against the Family `has_many :*_items`
  # reflections.
  ITEM_ASSOCIATIONS = %i[
    plaid_items
    lunchflow_items
    enable_banking_items
    coinstats_items
    coinbase_items
  ].freeze

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV[ENV_KEY]) == true
  end
end
