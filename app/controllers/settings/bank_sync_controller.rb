class Settings::BankSyncController < ApplicationController
  require_bank_connections

  layout "settings"

  # The enabled bank connection providers that have a page to read about them
  def show
    @providers = BankConnections.enabled_providers.select(&:docs_url).map do |provider|
      {
        name: provider.label,
        description: provider.description,
        path: provider.docs_url,
        target: "_blank",
        rel: "noopener noreferrer"
      }
    end
  end
end
