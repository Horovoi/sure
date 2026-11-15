# Shared steps of a bank connection controller's account linking flow.
#
#   class MonobankItemsController < ApplicationController
#     include ProviderConnectionFlow
#
#     def link_accounts
#       ...
#       redirect_to link_redirect_target(accounts_path)
#     end
#   end
module ProviderConnectionFlow
  extend ActiveSupport::Concern

  private
    # params[:return_to] when it is a path inside the app (see
    # StoreLocation#sanitize_return_to), else nil. Never a full URL.
    def safe_return_to_path
      sanitize_return_to(params[:return_to])
    end

    # Where to go after linking: the safe return_to, else default
    def link_redirect_target(default)
      safe_return_to_path || default
    end
end
