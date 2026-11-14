require "test_helper"

class ImpersonationSessionsControllerTest < ActionDispatch::IntegrationTest
  test "impersonation session logs all activity for auditing" do
    sign_in impersonator = users(:sure_support_staff)
    impersonated = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }

    assert_difference "impersonator_session.logs.count", 2 do
      get root_path
      get account_path(impersonated.family.accounts.first)
    end
  end

  test "super admin can request an impersonation session" do
    sign_in users(:sure_support_staff)

    post impersonation_sessions_path, params: { impersonation_session: { impersonated_id: users(:family_member).id } }

    assert_equal "Request sent to user. Waiting for approval.", flash[:notice]
    assert_redirected_to root_path
  end

  test "super admin can join and leave an in progress impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    super_admin_session = super_admin.sessions.order(created_at: :desc).first

    assert_nil super_admin_session.active_impersonator_session

    # Joining the session
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }
    assert_equal impersonator_session, super_admin_session.reload.active_impersonator_session
    assert_equal "Joined session", flash[:notice]
    assert_redirected_to root_path

    follow_redirect!

    # Leaving the session
    delete leave_impersonation_sessions_path
    assert_nil super_admin_session.reload.active_impersonator_session
    assert_equal "Left session", flash[:notice]
    assert_redirected_to root_path

    # Impersonation session still in progress because nobody has ended it yet
    assert_equal "in_progress", impersonator_session.reload.status
  end

  test "super admin can complete an impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    put complete_impersonation_session_path(impersonator_session)

    assert_equal "Session completed", flash[:notice]
    assert_nil super_admin.sessions.order(created_at: :desc).first.active_impersonator_session
    assert_equal "complete", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "regular user can complete an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    put complete_impersonation_session_path(impersonator_session)

    assert_equal "Session completed", flash[:notice]
    assert_equal "complete", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "super admin cannot accept an impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    put approve_impersonation_session_path(impersonator_session)

    assert_response :not_found
  end

  test "regular user can accept an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = ImpersonationSession.create!(impersonator: users(:sure_support_staff), impersonated: regular_user)

    put approve_impersonation_session_path(impersonator_session)

    assert_equal "Request approved", flash[:notice]
    assert_equal "in_progress", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "regular user can reject an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = ImpersonationSession.create!(impersonator: users(:sure_support_staff), impersonated: regular_user)

    put reject_impersonation_session_path(impersonator_session)

    assert_equal "Request rejected", flash[:notice]
    assert_equal "rejected", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "a completed session cannot be approved again" do
    sign_in users(:family_member)
    impersonator_session = impersonation_sessions(:in_progress)
    impersonator_session.complete!

    put approve_impersonation_session_path(impersonator_session)

    assert_redirected_to root_path
    assert_equal I18n.t("impersonation_sessions.invalid_transition"), flash[:alert]
    assert_equal "complete", impersonator_session.reload.status
  end

  test "completing a session detaches every browser session that joined it" do
    super_admin = users(:sure_support_staff)
    impersonator_session = impersonation_sessions(:in_progress)
    other_browser = super_admin.sessions.create!(active_impersonator_session: impersonator_session)

    sign_in users(:family_member)
    put complete_impersonation_session_path(impersonator_session)

    assert_nil other_browser.reload.active_impersonator_session_id
  end

  test "a pending session cannot be joined" do
    sign_in super_admin = users(:sure_support_staff)
    pending = ImpersonationSession.create!(impersonator: super_admin, impersonated: users(:empty))

    post join_impersonation_sessions_path, params: { impersonation_session_id: pending.id }

    assert_response :not_found
    assert_nil super_admin.sessions.order(created_at: :desc).first.active_impersonator_session_id
  end

  test "a demoted super admin stops impersonating at once" do
    sign_in super_admin = users(:sure_support_staff)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonation_sessions(:in_progress).id }

    get settings_profile_path
    assert_includes response.body, users(:family_member).email, "impersonating before the demotion"

    super_admin.update_column(:role, "admin")

    get settings_profile_path
    assert_not_includes response.body, users(:family_member).email
  end

  test "an expired session no longer impersonates" do
    sign_in users(:sure_support_staff)
    impersonator_session = impersonation_sessions(:in_progress)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }

    impersonator_session.update_column(:updated_at, 3.hours.ago)

    get settings_profile_path
    assert_not_includes response.body, users(:family_member).email
  end

  test "an impersonator cannot create API keys for the impersonated user" do
    sign_in users(:sure_support_staff)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonation_sessions(:in_progress).id }

    assert_no_difference "ApiKey.count" do
      post settings_api_key_path, params: { api_key: { name: "Sneaky", scopes: "read_write" } }
    end
    assert_equal I18n.t("impersonation_sessions.not_allowed_while_impersonating"), flash[:alert]
  end

  test "actions that raise while impersonating are still logged" do
    sign_in users(:sure_support_staff)
    impersonator_session = impersonation_sessions(:in_progress)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }

    assert_difference "impersonator_session.logs.count", 1 do
      get account_path(SecureRandom.uuid)
    end
  end
end
