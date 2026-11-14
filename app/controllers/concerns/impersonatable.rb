module Impersonatable
  extend ActiveSupport::Concern

  included do
    # around_action with ensure, so actions that raise are logged too
    around_action :log_impersonation_activity
  end

  class_methods do
    # Credential and account changes made while impersonating would outlive
    # the impersonation session, so they are refused.
    def disallow_while_impersonating(**options)
      before_action :reject_while_impersonating!, **options
    end
  end

  private
    def reject_while_impersonating!
      return unless Current.impersonated_user

      redirect_back_or_to root_path, alert: t("impersonation_sessions.not_allowed_while_impersonating")
    end

    def log_impersonation_activity
      yield
    ensure
      begin
        create_impersonation_session_log
      rescue StandardError => e
        Rails.logger.error("[Impersonation] failed to write audit log: #{e.message}")
      end
    end

    def create_impersonation_session_log
      return unless Current.impersonated_user

      Current.session.active_impersonator_session.logs.create!(
        controller: controller_name,
        action: action_name,
        path: request.fullpath,
        method: request.method,
        ip_address: request.ip,
        user_agent: request.user_agent
      )
    end
end
