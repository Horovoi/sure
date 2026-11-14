class MfaController < ApplicationController
  MFA_STEP_TTL = 10.minutes

  layout :determine_layout
  skip_authentication only: [ :verify, :verify_code ]

  def new
    redirect_to root_path if Current.user.otp_required?
    Current.user.setup_mfa! unless Current.user.otp_secret.present?
  end

  def create
    # Enabling is for setup in progress only; a wrong code must never turn
    # off MFA that is already on.
    return redirect_to root_path if Current.user.otp_required?

    if Current.user.verify_otp?(params[:code])
      Current.user.enable_mfa!
      @backup_codes = Current.user.otp_backup_codes
      render :backup_codes
    else
      Current.user.disable_mfa!
      redirect_to new_mfa_path, alert: t(".invalid_code")
    end
  end

  def verify
    @user = pending_mfa_user

    if @user.nil?
      redirect_to new_session_path
    end
  end

  def verify_code
    @user = pending_mfa_user

    if @user.nil?
      redirect_to new_session_path
    elsif @user.verify_otp?(params[:code])
      session.delete(:mfa_user_id)
      session.delete(:mfa_started_at)
      @session = create_session_for(@user)
      redirect_to after_sign_in_path_for(@user)
    else
      flash.now[:alert] = t(".invalid_code")
      render :verify, status: :unprocessable_entity
    end
  end

  # Turning MFA off needs a valid code from the authenticator app (or a
  # backup code), so a hijacked or impersonated session cannot strip it.
  def disable
    if Current.user != Current.true_user
      redirect_to settings_security_path, alert: t(".not_while_impersonating")
    elsif Current.user.verify_otp?(params[:code])
      Current.user.disable_mfa!
      redirect_to settings_security_path, notice: t(".success")
    else
      redirect_to settings_security_path, alert: t(".invalid_code")
    end
  end

  private
    # The password step of a login is valid for MFA_STEP_TTL only.
    def pending_mfa_user
      started_at = session[:mfa_started_at].to_i
      if session[:mfa_user_id].blank? || Time.current.to_i - started_at > MFA_STEP_TTL.to_i
        session.delete(:mfa_user_id)
        session.delete(:mfa_started_at)
        return nil
      end

      User.find_by(id: session[:mfa_user_id], active: true)
    end

    def determine_layout
      if action_name.in?(%w[verify verify_code])
        "auth"
      else
        "settings"
      end
    end
end
