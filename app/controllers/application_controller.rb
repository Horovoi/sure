class ApplicationController < ActionController::Base
  include RestoreLayoutPreferences, Onboardable, Localize, AutoSync, Authentication, Invitable,
          SelfHostable, StoreLocation, Impersonatable, Breadcrumbable,
          FeatureGuardable, BankConnectionsGuardable, Notifiable, SafePagination
  include Pundit::Authorization

  include Pagy::Backend

  # Pundit uses current_user by default, but this app uses Current.user
  def pundit_user
    Current.user
  end

  before_action :detect_os
  before_action :set_default_chat
  before_action :set_active_storage_url_options

  helper_method :demo_config, :demo_host_match?, :show_demo_warning?

  private
    # Where to go after signing in. A pending invitation found in the session
    # is never accepted silently: the user is sent to the invitation page and
    # accepts it there with an explicit click.
    def after_sign_in_path_for(user)
      token = session[:pending_invitation_token].to_s
      return root_path if token.blank? || user.blank?

      invitation = Invitation.pending.find_by(token: token)
      if invitation&.email.to_s.casecmp?(user.email.to_s)
        accept_invitation_path(invitation.token)
      else
        session.delete(:pending_invitation_token)
        root_path
      end
    end

    # Password (or SSO) step done; the MFA step must follow within
    # MfaController::MFA_STEP_TTL.
    def start_mfa_step_for(user)
      session[:mfa_user_id] = user.id
      session[:mfa_started_at] = Time.current.to_i
    end

    def store_pending_invitation_if_valid
      token = params[:invitation].to_s.presence
      return if token.blank?

      invitation = Invitation.pending.find_by(token: token)
      session[:pending_invitation_token] = token if invitation
    end

    def detect_os
      user_agent = request.user_agent
      @os = case user_agent
      when /Windows/i then "windows"
      when /Macintosh/i then "mac"
      when /Linux/i then "linux"
      when /Android/i then "android"
      when /iPhone|iPad/i then "ios"
      else ""
      end
    end

    # By default, we show the user the last chat they interacted with
    def set_default_chat
      @last_viewed_chat = Current.user&.last_viewed_chat
      @chat = @last_viewed_chat
    end

    def set_active_storage_url_options
      ActiveStorage::Current.url_options = {
        protocol: request.protocol,
        host: request.host,
        port: request.optional_port
      }
    end

    def demo_config
      Rails.application.config_for(:demo)
    rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError
      nil
    end

    def demo_host_match?(demo = demo_config)
      return false unless demo.is_a?(Hash) && demo["hosts"].present?

      demo["hosts"].include?(request.host)
    end

    def show_demo_warning?
      demo_host_match?
    end
end
