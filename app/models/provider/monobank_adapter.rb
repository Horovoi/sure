class Provider::MonobankAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("MonobankAccount", self)

  # Cards with a credit limit can be credit cards; everything else is cash.
  def self.supported_account_types
    %w[Depository CreditCard]
  end

  # One config per configured connection, only while monobank is enabled.
  def self.connection_configs(family:)
    return [] unless monobank_enabled?
    return [] unless family.respond_to?(:monobank_items)

    family.monobank_items.active.ordered.select(&:credentials_configured?).map do |monobank_item|
      connection_config_for(monobank_item)
    end
  end

  def self.monobank_enabled?
    defined?(BankConnections) && BankConnections.enabled?(:monobank)
  end

  def self.build_provider(family: nil, monobank_item_id: nil)
    return nil if family.blank?

    scope = family.monobank_items.active.ordered
    item = monobank_item_id.present? ? scope.find_by(id: monobank_item_id) : scope.find(&:credentials_configured?)
    item&.monobank_provider
  end

  def self.connection_config_for(monobank_item)
    helpers = Rails.application.routes.url_helpers

    {
      key: "monobank_#{monobank_item.id}",
      name: monobank_item.name.presence || I18n.t("monobank_items.defaults.name"),
      description: I18n.t("monobank_items.defaults.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        helpers.select_accounts_monobank_items_path(
          monobank_item_id: monobank_item.id, accountable_type: accountable_type, return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        helpers.select_existing_account_monobank_items_path(monobank_item_id: monobank_item.id, account_id: account_id)
      }
    }
  end
  private_class_method :connection_config_for

  def provider_name
    "monobank"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_monobank_item_path(item)
  end

  def item
    provider_account.monobank_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    item&.institution_domain.presence || MonobankAccount::INSTITUTION_DOMAIN
  end

  def institution_name
    item&.institution_name.presence || MonobankAccount::INSTITUTION_NAME
  end

  def institution_url
    item&.institution_url.presence || "https://#{MonobankAccount::INSTITUTION_DOMAIN}"
  end

  def institution_color
    item&.institution_color
  end
end
