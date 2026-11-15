# Responds 404 to the actions of a bank or crypto connection provider controller
# while that provider is off (see BankConnections), so its pages and webhooks
# can't be reached by URL. The check runs before authentication, so a signed-out
# visitor also gets a 404 instead of a login redirect.
#
# provider: the BankConnections key the controller belongs to. Without one, the
# actions are reachable while any provider is on (shared pages such as Settings >
# Sync Providers).
#
# Example:
#
# class PlaidItemsController < ApplicationController
#   require_bank_connections provider: :plaid
# end
#
module BankConnectionsGuardable
  extend ActiveSupport::Concern

  class_methods do
    def require_bank_connections(provider: nil, **options)
      prepend_before_action(**options) { ensure_bank_connections_enabled(provider) }
    end
  end

  private
    def ensure_bank_connections_enabled(provider = nil)
      raise ActionController::RoutingError, "Not Found" unless BankConnections.enabled?(provider)
    end
end
