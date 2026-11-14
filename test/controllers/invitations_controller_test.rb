require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @admin = users(:family_admin)
    @invitation = invitations(:one)
  end

  test "should get new" do
    get new_invitation_url
    assert_response :success
  end

  test "should create invitation for member" do
    assert_difference("Invitation.count") do
      assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
        post invitations_url, params: {
          invitation: {
            email: "new@example.com",
            role: "member"
          }
        }
      end
    end

    invitation = Invitation.order(created_at: :desc).first
    assert_equal "member", invitation.role
    assert_equal @admin, invitation.inviter
    assert_equal "new@example.com", invitation.email
    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
  end

  test "non-admin cannot create invitations" do
    sign_in users(:family_member)

    assert_no_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "new@example.com",
          role: "admin"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "admin can create admin invitation" do
    assert_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "new@example.com",
          role: "admin"
        }
      }
    end

    invitation = Invitation.order(created_at: :desc).first
    assert_equal "admin", invitation.role
    assert_equal @admin.family, invitation.family
    assert_equal @admin, invitation.inviter
  end

  test "should handle invalid invitation creation" do
    assert_no_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "",
          role: "member"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "should accept invitation and render account choice" do
    get accept_invitation_url(@invitation.token)
    assert_response :success
    assert_select "a[href='#{new_registration_path(invitation: @invitation.token)}']"
    assert_select "a[href='#{new_session_path(invitation: @invitation.token)}']"
  end

  test "inviting an existing user leaves them in place until they accept" do
    invited_user = users(:empty)
    original_family = invited_user.family

    assert_difference("Invitation.count") do
      post invitations_url, params: { invitation: { email: invited_user.email, role: "member" } }
    end

    invitation = Invitation.order(created_at: :desc).first

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.existing_user"), flash[:notice]
    assert invitation.pending?
    assert_equal original_family, invited_user.reload.family
    assert_equal "admin", invited_user.role
  end

  test "a lapsed invitation does not block inviting the same email again" do
    @invitation.update_columns(expires_at: 1.day.ago)

    post invitations_url, params: { invitation: { email: @invitation.email, role: "member" } }

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
    assert_equal 1, Invitation.where(email: @invitation.email, family: @admin.family).count
    assert Invitation.find_by(email: @invitation.email, family: @admin.family).pending?
  end

  test "signed-in invitee sees an accept button and joins only after confirming" do
    invited_user = users(:empty)
    invitation = @admin.family.invitations.create!(email: invited_user.email, role: "member", inviter: @admin)

    delete session_path(@admin.sessions.order(:created_at).last)
    sign_in invited_user

    get accept_invitation_url(invitation.token)
    assert_response :success
    assert_select "form[action='#{confirm_invitation_path(invitation.token)}']"
    assert_equal users(:empty).family, invited_user.reload.family

    post confirm_invitation_url(invitation.token)

    assert_redirected_to root_path
    assert_equal @admin.family, invited_user.reload.family
    assert_equal "member", invited_user.role
    assert invitation.reload.accepted_at.present?

    # A second submit of the same form
    post confirm_invitation_url(invitation.token)
    assert_redirected_to root_path
    assert_equal I18n.t("invitations.confirm.no_longer_pending"), flash[:alert]
  end

  test "accepting an invitation never changes a super admin's role" do
    super_admin = users(:sure_support_staff)
    invitation = @admin.family.invitations.create!(email: super_admin.email, role: "member", inviter: @admin)

    delete session_path(@admin.sessions.order(:created_at).last)
    sign_in super_admin
    post confirm_invitation_url(invitation.token)

    assert_equal @admin.family, super_admin.reload.family
    assert_equal "super_admin", super_admin.role
  end

  test "another user cannot confirm someone else's invitation" do
    other = users(:empty)
    invitation = @admin.family.invitations.create!(email: "someone@example.com", role: "member", inviter: @admin)

    delete session_path(@admin.sessions.order(:created_at).last)
    sign_in other
    post confirm_invitation_url(invitation.token)

    assert_redirected_to root_path
    assert invitation.reload.pending?
    assert_equal users(:empty).family, other.reload.family
  end

  test "signing in from an invitation link sends the user to the accept page without moving them" do
    invited_user = users(:empty)
    invitation = @admin.family.invitations.create!(email: invited_user.email, role: "member", inviter: @admin)
    delete session_path(@admin.sessions.order(:created_at).last)

    get new_session_url(invitation: invitation.token)
    post sessions_url, params: { email: invited_user.email, password: user_password_test }

    assert_redirected_to accept_invitation_path(invitation.token)
    assert invitation.reload.pending?
    assert_equal users(:empty).family, invited_user.reload.family
  end

  test "should not accept invalid invitation token" do
    get accept_invitation_url("invalid-token")
    assert_response :not_found
  end

  test "admin can remove pending invitation" do
    assert_difference("Invitation.count", -1) do
      delete invitation_url(@invitation)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.destroy.success"), flash[:notice]
  end

  test "non-admin cannot remove invitations" do
    sign_in users(:family_member)

    assert_no_difference("Invitation.count") do
      delete invitation_url(@invitation)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.destroy.not_authorized"), flash[:alert]
  end

  test "should handle invalid invitation removal" do
    delete invitation_url(id: "invalid-id")
    assert_response :not_found
  end
end
