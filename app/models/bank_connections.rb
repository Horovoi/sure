# The bank and crypto connection providers (Plaid, Lunch Flow, Enable Banking,
# CoinStats, Coinbase, monobank, ...) and the switch that turns each one on.
#
# Every provider is off by default. While one is off, the app hides every way to
# connect, link or manage it, its controllers and webhooks respond 404, and its
# items are not synced. Existing records are left untouched, and accounts linked
# to it keep syncing as manual accounts would.
#
# BANK_CONNECTIONS_ENABLED picks the providers that are on:
#   unset, "", "false", "0", "no" -> none
#   "true", "1", "yes"            -> every registered provider
#   "monobank" or "monobank,plaid" -> only those keys (comma or space separated;
#                                    unknown keys are ignored with a warning)
#
# Market data (Twelve Data, Yahoo Finance, NBU) and LLM providers are not
# affected by this switch.
#
# A provider registers once, here or from its own initializer (inside
# Rails.application.config.to_prepare, so it survives code reloading):
#
#   BankConnections.register(:monobank, association: :monobank_items,
#     item_class_name: "MonobankItem", account_class_name: "MonobankAccount",
#     label: "monobank", hourly: true)
module BankConnections
  ENV_KEY = "BANK_CONNECTIONS_ENABLED".freeze

  NONE_VALUES = %w[false 0 no off].freeze
  ALL_VALUES = %w[true 1 yes on].freeze

  # key: String; association: Family has_many of the items (Symbol);
  # item_class_name/account_class_name: the *_item and *_account models;
  # label/description/docs_url: shown on Settings > Bank Sync;
  # hourly: SyncHourlyJob syncs its items every hour;
  # balance_includes_pending: the provider's balance already counts open holds;
  # settings_partial: panel on Settings > Sync Providers (nil: none);
  # config_keys: Provider::ConfigurationRegistry keys shown on that page;
  # generic_listing: the accounts page renders its items with their own partial.
  Provider = Data.define(:key, :association, :item_class_name, :account_class_name, :label,
    :description, :docs_url, :hourly, :balance_includes_pending, :settings_partial, :config_keys, :generic_listing) do
    def item_class
      item_class_name.constantize
    end

    def hourly? = hourly
    def balance_includes_pending? = balance_includes_pending
    def generic_listing? = generic_listing
  end

  class << self
    # Adds (or replaces) a provider. Registration order is sync order.
    def register(key, association:, item_class_name:, account_class_name:, label:, description: nil,
      docs_url: nil, hourly: false, balance_includes_pending: false, settings_partial: nil, config_keys: [], generic_listing: false)
      provider = Provider.new(
        key: key.to_s, association: association.to_sym, item_class_name: item_class_name.to_s,
        account_class_name: account_class_name.to_s, label: label, description: description, docs_url: docs_url,
        hourly: hourly, balance_includes_pending: balance_includes_pending, settings_partial: settings_partial,
        config_keys: Array(config_keys).map(&:to_s).freeze, generic_listing: generic_listing
      )

      registry[provider.key] = provider
      provider
    end

    # Every registered provider, in registration order
    def providers
      registry.values
    end

    def provider(key)
      return nil if key.nil?

      registry[key.to_s]
    end

    # The keys of the providers that are on. The one source of truth: every other
    # method reads it (tests stub it, see enable_bank_connections).
    def enabled_keys
      parse(ENV[ENV_KEY])
    end

    # Without a key: whether any provider is on. With a key: whether that one is.
    def enabled?(key = nil)
      keys = enabled_keys
      key.nil? ? keys.any? : keys.include?(key.to_s)
    end

    def enabled_providers
      keys = enabled_keys
      providers.select { |provider| keys.include?(provider.key) }
    end

    # Family associations that hold provider items, in sync order. The family reset
    # walks all of them (enabled_only: false); the family sync only the enabled ones.
    def item_associations(enabled_only: false)
      (enabled_only ? enabled_providers : providers).map(&:association)
    end

    def provider_for_account_class(class_name)
      providers.find { |provider| provider.account_class_name == class_name.to_s }
    end

    def provider_for_item_class(class_name)
      providers.find { |provider| provider.item_class_name == class_name.to_s }
    end

    def enabled_account_class_names
      enabled_providers.map(&:account_class_name)
    end

    private
      def registry
        @registry ||= {}
      end

      def parse(value)
        normalized = value.to_s.strip.downcase
        return Set.new if normalized.empty? || NONE_VALUES.include?(normalized)
        return Set.new(registry.keys) if ALL_VALUES.include?(normalized)

        keys = normalized.split(/[\s,]+/).reject(&:empty?)
        unknown = keys - registry.keys
        Rails.logger.warn("#{ENV_KEY}: unknown bank connection keys ignored: #{unknown.join(', ')}") if unknown.any?

        Set.new(keys & registry.keys)
      end
  end

  register :plaid,
    association: :plaid_items, item_class_name: "PlaidItem", account_class_name: "PlaidAccount",
    label: "Plaid",
    description: "US & Canada bank connections with transactions, investments, and liabilities.",
    docs_url: "https://github.com/we-promise/sure/blob/main/docs/hosting/plaid.md",
    config_keys: %w[plaid plaid_eu]

  register :lunchflow,
    association: :lunchflow_items, item_class_name: "LunchflowItem", account_class_name: "LunchflowAccount",
    label: "Lunch Flow",
    description: "US, Canada, UK, EU, Brazil and Asia through multiple open banking providers.",
    docs_url: "https://lunchflow.app/features/sure-integration",
    settings_partial: "settings/providers/lunchflow_panel"

  register :enable_banking,
    association: :enable_banking_items, item_class_name: "EnableBankingItem", account_class_name: "EnableBankingAccount",
    label: "Enable Banking (beta)",
    description: "European bank connections via open banking APIs across multiple countries.",
    docs_url: "https://enablebanking.com",
    settings_partial: "settings/providers/enable_banking_panel"

  # https://coinstats.app/api-docs/rate-limits#plan-limits
  register :coinstats,
    association: :coinstats_items, item_class_name: "CoinstatsItem", account_class_name: "CoinstatsAccount",
    label: "CoinStats (beta)",
    hourly: true,
    settings_partial: "settings/providers/coinstats_panel"

  register :coinbase,
    association: :coinbase_items, item_class_name: "CoinbaseItem", account_class_name: "CoinbaseAccount",
    label: "Coinbase (beta)",
    settings_partial: "settings/providers/coinbase_panel"
end
