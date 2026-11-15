class Settings::ProvidersController < ApplicationController
  require_bank_connections

  layout "settings"

  guard_feature unless: -> { self_hosted? }

  include FamilyAdminRequired

  require_family_admin only: [ :show, :update ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Sync Providers", nil ]
    ]

    prepare_show_context
  end

  def update
    # Build index of valid configurable fields with their metadata (enabled providers only)
    valid_fields = {}
    enabled_configurations.each do |config|
      config.fields.each do |field|
        valid_fields[field.setting_key.to_s] = field
      end
    end

    updated_fields = []

    # Perform all updates within a transaction for consistency
    Setting.transaction do
      provider_params.each do |param_key, param_value|
        # Only process keys that exist in the configuration registry
        field = valid_fields[param_key.to_s]
        next unless field

        # Clean the value and convert blank/empty strings to nil
        value = param_value.to_s.strip
        value = nil if value.empty?

        # For secret fields only, skip placeholder values to prevent accidental overwrite
        if field.secret && value == "********"
          next
        end

        key_str = field.setting_key.to_s

        # Check if the setting is a declared field in setting.rb
        # Use method_defined? to check if the setter actually exists on the singleton class,
        # not just respond_to? which returns true for dynamic fields due to respond_to_missing?
        if Setting.singleton_class.method_defined?("#{key_str}=")
          # If it's a declared field (e.g., openai_model), set it directly.
          # This is safe and uses the proper setter.
          Setting.public_send("#{key_str}=", value)
        else
          # If it's a dynamic field, set it as an individual entry
          # Each field is stored independently, preventing race conditions
          Setting[key_str] = value
        end

        updated_fields << param_key
      end
    end

    if updated_fields.any?
      # Reload provider configurations if needed
      reload_provider_configs(updated_fields)

      redirect_to settings_providers_path, notice: "Provider settings updated successfully"
    else
      redirect_to settings_providers_path, notice: "No changes were made"
    end
  rescue => error
    Rails.logger.error("Failed to update provider settings: #{error.message}")
    flash.now[:alert] = "Failed to update provider settings: #{error.message}"
    prepare_show_context
    render :show, status: :unprocessable_entity
  end

  private
    def provider_params
      # Dynamically permit the configuration fields of the enabled providers
      permitted_fields = []

      enabled_configurations.each do |config|
        config.fields.each do |field|
          permitted_fields << field.setting_key
        end
      end

      return {} if permitted_fields.empty?

      params.expect(setting: permitted_fields)
    end

    # Reload provider configurations after settings update
    def reload_provider_configs(updated_fields)
      # Build a set of provider keys that had fields updated
      updated_provider_keys = Set.new

      # Look up the provider key directly from the configuration registry
      updated_fields.each do |field_key|
        Provider::ConfigurationRegistry.all.each do |config|
          field = config.fields.find { |f| f.setting_key.to_s == field_key.to_s }
          if field
            updated_provider_keys.add(field.provider_key)
            break
          end
        end
      end

      # Reload configuration for each updated provider
      updated_provider_keys.each do |provider_key|
        adapter_class = Provider::ConfigurationRegistry.get_adapter_class(provider_key)
        adapter_class&.reload_configuration
      end
    end

    # The global configurations (Provider::ConfigurationRegistry) of the enabled
    # providers: each provider lists its keys in config_keys (Plaid: plaid, plaid_eu)
    def enabled_configurations
      Provider::Factory.ensure_adapters_loaded
      keys = BankConnections.enabled_providers.flat_map(&:config_keys)
      Provider::ConfigurationRegistry.all.select { |config| keys.include?(config.provider_key.to_s) }
    end

    # Prepares instance vars needed by the show view and partials
    def prepare_show_context
      @provider_configurations = enabled_configurations
      # Family-scoped connections render their own panel (BankConnections settings_partial)
      @provider_panels = BankConnections.enabled_providers.select(&:settings_partial)

      # Providers page only needs to know whether Lunchflow connections exist with valid credentials
      @lunchflow_items = Current.family.lunchflow_items.where.not(api_key: [ nil, "" ]).ordered.select(:id)
      @enable_banking_items = Current.family.enable_banking_items.ordered # Enable Banking panel needs session info for status display
      @coinstats_items = Current.family.coinstats_items.ordered # CoinStats panel needs account info for status display
      @coinbase_items = Current.family.coinbase_items.ordered # Coinbase panel needs name and sync info for status display
    end
end
