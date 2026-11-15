class UsersController < ApplicationController
  before_action :set_user
  before_action :ensure_admin, only: %i[reset reset_with_sample_data]
  disallow_while_impersonating only: :destroy
  before_action :reject_email_change_while_impersonating, only: :update

  def resend_confirmation_email
    if @user.resend_confirmation_email
      redirect_to settings_profile_path, notice: t(".success")
    else
      redirect_to settings_profile_path, alert: t(".no_pending_change")
    end
  end

  def update
    @user = Current.user

    if email_changed?
      if @user.initiate_email_change(user_params[:email])
        if Rails.application.config.app_mode.self_hosted? && !Setting.require_email_confirmation
          handle_redirect(t(".success"))
        else
          redirect_to settings_profile_path, notice: t(".email_change_initiated")
        end
      else
        error_message = @user.errors.any? ? @user.errors.full_messages.to_sentence : t(".email_change_failed")
        redirect_to settings_profile_path, alert: error_message
      end
    else
      was_ai_enabled = @user.ai_enabled
      @user.assign_attributes(onboarding_step_timestamps)
      # A rejected value (an unknown family time zone or currency) is shown, not a 500
      unless @user.update(user_params.except(:redirect_to, :delete_profile_image, :onboarding_step))
        respond_to do |format|
          format.html { redirect_to(user_params[:redirect_to] == "preferences" ? settings_preferences_path : settings_profile_path, alert: @user.errors.full_messages.to_sentence) }
          format.json { render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity }
        end
        return
      end
      @user.profile_image.purge if should_purge_profile_image?

      # Add a special notice if AI was just enabled or disabled
      notice = if family_change_refused?
        t(".family_settings_admin_only")
      elsif !was_ai_enabled && @user.ai_enabled
        "AI Assistant has been enabled successfully."
      elsif was_ai_enabled && !@user.ai_enabled
        "AI Assistant has been disabled."
      else
        t(".success")
      end

      respond_to do |format|
        format.html { handle_redirect(notice) }
        format.json { head :ok }
      end
    end
  end

  def reset
    FamilyResetJob.perform_later(Current.family)
    redirect_to settings_profile_path, notice: t(".success")
  end

  def reset_with_sample_data
    FamilyResetJob.perform_later(Current.family, load_sample_data_for_email: @user.email)
    redirect_to settings_profile_path, notice: t(".success")
  end

  def destroy
    # deactivate revokes every session, API key and OAuth token of the user
    if @user.deactivate
      cookies.delete(:session_token)
      reset_session
      redirect_to root_path, notice: t(".success")
    else
      redirect_to settings_profile_path, alert: @user.errors.full_messages.to_sentence
    end
  end

  def rule_prompt_settings
    @user.update!(rule_prompt_settings_params)
    redirect_back_or_to settings_profile_path
  end

  private
    def handle_redirect(notice)
      case user_params[:redirect_to]
      when "onboarding_preferences"
        redirect_to preferences_onboarding_path
      when "home"
        redirect_to root_path
      when "budgeting"
        redirect_to settings_budgeting_path, notice: notice
      when "preferences"
        redirect_to settings_preferences_path, notice: notice
      when "goals"
        redirect_to goals_onboarding_path
      when "ai_prompts"
        redirect_to settings_ai_prompts_path, notice: notice
      else
        redirect_to settings_profile_path, notice: notice
      end
    end

    # The server stamps onboarding progress; the client only names the step
    # it just finished.
    def onboarding_step_timestamps
      now = Time.current

      case user_params[:onboarding_step]
      when "preferences"
        { set_onboarding_preferences_at: now }
      when "goals"
        { set_onboarding_goals_at: now, onboarded_at: now }
      when "invitation"
        { onboarded_at: now }
      else
        {}
      end
    end

    def should_purge_profile_image?
      user_params[:delete_profile_image] == "1" &&
        user_params[:profile_image].blank?
    end

    def email_changed?
      user_params[:email].present? && user_params[:email] != @user.email
    end

    def rule_prompt_settings_params
      params.expect(user: [ :rule_prompt_dismissed_at, :rule_prompts_disabled ])
    end

    # Household settings (currency, locale, fiscal months, ...) belong to the
    # whole family, so only a family admin may change them.
    def family_attributes_refused?
      params.dig(:user, :family_attributes).present? && !Current.user.admin?
    end

    # The preferences form always sends the family id, so only a real setting counts as a refused change
    def family_change_refused?
      family_attributes_refused? && params.dig(:user, :family_attributes).except(:id).present?
    end

    def user_params
      permitted = params.expect(user: [
        :first_name, :last_name, :email, :profile_image, :redirect_to, :delete_profile_image, :onboarding_step,
        :show_sidebar, :default_period, :default_account_order, :show_ai_sidebar, :ai_enabled, :theme,
        family_attributes: [ :name, :currency, :country, :locale, :date_format, :timezone, :use_fiscal_months, :fiscal_month_start_day, :id, { enabled_currencies: [] } ],
        goals: []
      ])
      family_attributes_refused? ? permitted.except(:family_attributes) : permitted
    end

    def set_user
      @user = Current.user
    end

    def reject_email_change_while_impersonating
      return unless params.dig(:user, :email).present? && email_changed?

      reject_while_impersonating!
    end

    def ensure_admin
      redirect_to settings_profile_path, alert: I18n.t("users.reset.unauthorized") unless Current.user.admin?
    end
end
