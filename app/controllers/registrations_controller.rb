class RegistrationsController < ApplicationController
  skip_authentication

  layout "auth"

  before_action :ensure_signup_open
  before_action :set_user, only: :create
  before_action :set_invitation
  before_action :validate_password_requirements, only: :create

  def new
    @user = User.new(email: @invitation&.email)
  end

  def create
    if @invitation
      @user.family = @invitation.family
      @user.role = @invitation.role
      @user.email = @invitation.email
    else
      family = Family.new
      @user.family = family
      @user.role = User.role_for_new_family_creator
    end

    # Claim the invite code, create the user and accept the invitation in one
    # transaction: a failed save keeps the code, and two signups cannot
    # share one code or one invitation.
    outcome = nil
    User.transaction do
      if invite_code_required? && !InviteCode.claim!(user_params[:invite_code])
        outcome = :invalid_invite_code
        raise ActiveRecord::Rollback
      end

      if @invitation && !@invitation.claim_for_signup!
        outcome = :invitation_used
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback unless @user.save

      outcome = :created
    end

    case outcome
    when :created
      @session = create_session_for(@user)
      redirect_to root_path, notice: t(".success")
    when :invalid_invite_code
      redirect_to new_registration_path, alert: t("registrations.create.invalid_invite_code")
    when :invitation_used
      redirect_to new_registration_path, alert: t("registrations.create.invitation_used")
    else
      render :new, status: :unprocessable_entity, alert: t(".failure")
    end
  end

  private

    def set_invitation
      token = params[:invitation]
      token ||= params[:user][:invitation] if params[:user].present?
      @invitation = Invitation.pending.find_by(token: token)
    end

    def set_user
      @user = User.new user_params.except(:invite_code, :invitation)
    end

    def user_params(specific_param = nil)
      params = self.params.expect(user: [ :name, :email, :password, :password_confirmation, :invite_code, :invitation ])
      specific_param ? params[specific_param] : params
    end

    def validate_password_requirements
      password = user_params[:password]
      return if password.blank? # Let Rails built-in validations handle blank passwords

      if password.length < 8
        @user.errors.add(:password, "must be at least 8 characters")
      end

      unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
        @user.errors.add(:password, "must include both uppercase and lowercase letters")
      end

      unless password.match?(/\d/)
        @user.errors.add(:password, "must include at least one number")
      end

      unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)
        @user.errors.add(:password, "must include at least one special character")
      end

      if @user.errors.present?
        render :new, status: :unprocessable_entity
      end
    end

    def ensure_signup_open
      return unless signup_closed?

      redirect_to new_session_path, alert: t("registrations.closed")
    end
end
