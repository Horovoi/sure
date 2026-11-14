class OidcAccountsController < ApplicationController
  skip_authentication only: [ :link, :create_link, :new_user, :create_user ]
  layout "auth"

  def link
    # Check if there's pending OIDC auth in session
    @pending_auth = pending_oidc_auth

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    @email = @pending_auth["email"]
    @user_exists = User.exists?(email: @email) if @email.present?

    # Determine whether we should offer JIT account creation for this
    # pending auth, based on JIT mode and allowed domains.
    @allow_account_creation = jit_signup_allowed?(@email)
  end

  def create_link
    @pending_auth = pending_oidc_auth

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    # Verify user's password to confirm identity. Linking is a password
    # login, so it follows the same local-login rules as the login form.
    user = User.authenticate_by(email: params[:email], password: params[:password])
    user = nil unless user&.active? && AuthConfig.local_login_allowed_for?(user)

    if user
      # Create the OIDC identity link
      oidc_identity = OidcIdentity.create_from_omniauth(
        build_auth_hash(@pending_auth),
        user
      )

      # Log account linking
      SsoAuditLog.log_link!(
        user: user,
        provider: @pending_auth["provider"],
        request: request
      )

      # Clear pending auth from session
      session.delete(:pending_oidc_auth)

      # Check if user has MFA enabled
      if user.otp_required?
        start_mfa_step_for(user)
        redirect_to verify_mfa_path
      else
        @session = create_session_for(user)
        redirect_to after_sign_in_path_for(user), notice: "Account successfully linked to #{@pending_auth['provider']}"
      end
    else
      @email = params[:email]
      @user_exists = User.exists?(email: @email) if @email.present?
      flash.now[:alert] = "Invalid email or password"
      render :link, status: :unprocessable_entity
    end
  end

  def new_user
    # Check if there's pending OIDC auth in session
    @pending_auth = pending_oidc_auth

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    # Pre-fill user details from OIDC provider
    @user = User.new(
      email: @pending_auth["email"],
      first_name: @pending_auth["first_name"],
      last_name: @pending_auth["last_name"]
    )
  end

  def create_user
    @pending_auth = pending_oidc_auth

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    email = @pending_auth["email"]

    # Respect global JIT configuration and the instance signup gate: in
    # link_only mode, when the email domain is not allowed, or when signup is
    # closed (or invite-only without an invitation for this email), block JIT
    # account creation and send the user back to the login page.
    unless jit_signup_allowed?(email)
      redirect_to new_session_path, alert: "SSO account creation is disabled. Please contact an administrator."
      return
    end

    # Create SSO-only user without local password.
    # Security: JIT users should NOT have password_digest set to prevent
    # chained authentication attacks where SSO users gain local login access
    # via password reset.
    # Allow user to edit first_name and last_name from the form, but email comes from OIDC
    user_params = params.fetch(:user, {}).permit(:first_name, :last_name)
    @user = User.new(
      email: email,
      first_name: user_params[:first_name].presence || @pending_auth["first_name"],
      last_name: user_params[:last_name].presence || @pending_auth["last_name"],
      skip_password_validation: true
    )

    # Create new family for this user
    @user.family = Family.new

    # Use provider-configured default role, or fall back to admin for family creators
    # First user of an instance always becomes super_admin regardless of provider config
    provider_config = Rails.configuration.x.auth.sso_providers&.find { |p| p[:name] == @pending_auth["provider"] }
    provider_default_role = provider_config&.dig(:settings, :default_role)
    @user.role = User.role_for_new_family_creator(fallback_role: provider_default_role || :admin)

    if @user.save
      # Create the OIDC (or other SSO) identity
      identity = OidcIdentity.create_from_omniauth(
        build_auth_hash(@pending_auth),
        @user
      )

      # Only log JIT account creation if identity was successfully created
      if identity.persisted?
        SsoAuditLog.log_jit_account_created!(
          user: @user,
          provider: @pending_auth["provider"],
          request: request
        )
      end

      # Clear pending auth from session
      session.delete(:pending_oidc_auth)

      # Create session and log them in
      @session = create_session_for(@user)
      redirect_to after_sign_in_path_for(@user), notice: "Welcome! Your account has been created."
    else
      render :new_user, status: :unprocessable_entity
    end
  end

  PENDING_AUTH_TTL = 15.minutes

  private
    # The IdP login waiting to be linked or turned into an account. It is
    # only valid for PENDING_AUTH_TTL after the IdP callback.
    def pending_oidc_auth
      pending = session[:pending_oidc_auth]
      return nil if pending.blank?

      if Time.current.to_i - pending["started_at"].to_i > PENDING_AUTH_TTL.to_i
        session.delete(:pending_oidc_auth)
        return nil
      end

      pending
    end

    def jit_signup_allowed?(email)
      return false if AuthConfig.jit_link_only?
      return false unless AuthConfig.allowed_oidc_domain?(email)
      return false if signup_closed?

      # invite_code_required? is false when @invitation is set: a pending
      # invitation for this email stands in for an invite code.
      @invitation = pending_session_invitation_for(email)
      !invite_code_required?
    end

    def pending_session_invitation_for(email)
      token = session[:pending_invitation_token].to_s
      return nil if token.blank? || email.blank?

      invitation = Invitation.pending.find_by(token: token)
      invitation if invitation&.email.to_s.casecmp?(email.to_s)
    end

    # Convert pending auth hash to OmniAuth-like structure
    def build_auth_hash(pending_auth)
      OpenStruct.new(
        provider: pending_auth["provider"],
        uid: pending_auth["uid"],
        info: OpenStruct.new(pending_auth.slice("email", "name", "first_name", "last_name"))
      )
    end
end
