class Settings::BankSyncController < ApplicationController
  require_bank_connections

  layout "settings"

  # The enabled bank connection providers. A provider with a settings panel opens it
  # here in the app (where it is connected); one without links to its own page.
  def show
    @providers = BankConnections.enabled_providers.filter_map do |provider|
      if provider.settings_partial.present?
        { name: provider.label, description: provider.description, path: settings_providers_path(open: provider.key) }
      elsif provider.docs_url.present?
        { name: provider.label, description: provider.description, path: provider.docs_url,
          target: "_blank", rel: "noopener noreferrer" }
      end
    end
  end
end
