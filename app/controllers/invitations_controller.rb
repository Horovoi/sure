class InvitationsController < ApplicationController
  skip_authentication only: :accept
  def new
    @invitation = Invitation.new
  end

  # Creating an invitation never moves anyone. An existing user joins only
  # after opening the invitation link and accepting it from their own session.
  def create
    unless Current.user.admin?
      flash[:alert] = t(".failure")
      redirect_to settings_profile_path
      return
    end

    Invitation.clear_lapsed_for!(family: Current.family, email: invitation_params[:email])

    @invitation = Current.family.invitations.build(invitation_params)
    @invitation.inviter = Current.user

    if @invitation.save
      InvitationMailer.invite_email(@invitation).deliver_later unless self_hosted?

      flash[:notice] = if User.exists?(email: @invitation.email)
        t(".existing_user")
      else
        t(".success")
      end
    else
      flash[:alert] = t(".failure")
    end

    redirect_to settings_profile_path
  end

  def accept
    @invitation = Invitation.pending.find_by!(token: params[:id])

    # Authentication is skipped here so that signed-out people can choose to
    # sign in or sign up. A signed-in user may accept directly.
    @signed_in_user = find_session_by_cookie&.user

    render :accept_choice, layout: "auth"
  end

  def confirm
    invitation = Invitation.pending.find_by(token: params[:id])

    # A second submit (double click, back button) after the invitation was used
    return redirect_to root_path, alert: t(".no_longer_pending") unless invitation

    # Only the invited user, in their own (not an impersonated) session
    if Current.user != Current.true_user || !invitation.email.casecmp?(Current.true_user.email)
      redirect_to root_path, alert: t(".wrong_user")
      return
    end

    if invitation.accept_for(Current.true_user)
      session.delete(:pending_invitation_token)
      redirect_to root_path, notice: t(".success", family: invitation.family.name)
    else
      redirect_to accept_invitation_path(invitation.token),
        alert: invitation.errors.full_messages.to_sentence.presence || t(".failure")
    end
  end

  def destroy
    unless Current.user.admin?
      flash[:alert] = t("invitations.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    @invitation = Current.family.invitations.find(params[:id])

    if @invitation.destroy
      flash[:notice] = t("invitations.destroy.success")
    else
      flash[:alert] = t("invitations.destroy.failure")
    end

    redirect_to settings_profile_path
  end

  private

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end
end
