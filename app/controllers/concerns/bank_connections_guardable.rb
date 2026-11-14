# Responds 404 to the actions of a bank or crypto connection provider
# controller while BankConnections is disabled, so the provider pages and
# webhooks can't be reached by URL. The check runs before authentication, so
# a signed-out visitor also gets a 404 instead of a login redirect.
#
# Example:
#
# class PlaidItemsController < ApplicationController
#   require_bank_connections
# end
#
module BankConnectionsGuardable
  extend ActiveSupport::Concern

  class_methods do
    def require_bank_connections(**options)
      prepend_before_action :ensure_bank_connections_enabled, **options
    end
  end

  private
    def ensure_bank_connections_enabled
      raise ActionController::RoutingError, "Not Found" unless BankConnections.enabled?
    end
end
