require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "new" do
    get new_registration_url
    assert_response :success
  end

  test "create redirects to correct URL" do
    post registration_url, params: { user: {
      email: "john@example.com",
      password: "Password1!" } }

    assert_redirected_to root_url
  end

  test "first user of instance becomes super_admin" do
    # Clear all users to simulate fresh instance
    User.destroy_all

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "firstuser@example.com",
        password: "Password1!" } }
    end

    first_user = User.find_by(email: "firstuser@example.com")
    assert first_user.super_admin?, "First user should be super_admin"
  end

  test "subsequent users become admin not super_admin" do
    # Ensure users exist from fixtures
    assert User.exists?

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "seconduser@example.com",
        password: "Password1!" } }
    end

    new_user = User.find_by(email: "seconduser@example.com")
    assert new_user.admin?, "Subsequent user should be admin"
    assert_not new_user.super_admin?, "Subsequent user should not be super_admin"
  end

  test "create when hosted requires an invite code" do
    with_env_overrides REQUIRE_INVITE_CODE: "true" do
      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!" } }
        assert_redirected_to new_registration_url

        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!",
          invite_code: "foo" } }
        assert_redirected_to new_registration_url
      end

      assert_difference "User.count", +1 do
        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!",
          invite_code: InviteCode.generate! } }
        assert_redirected_to root_url
      end
    end
  end

  test "a signup that fails validation keeps the invite code" do
    with_env_overrides REQUIRE_INVITE_CODE: "true" do
      code = InviteCode.generate!

      assert_no_difference [ "User.count", "InviteCode.count" ] do
        # Weak password: rejected before anything is written
        post registration_url, params: { user: { email: "john@example.com", password: "weak", invite_code: code } }
        # Taken email: rejected by the model on save
        post registration_url, params: { user: { email: users(:family_admin).email, password: "Password1!", invite_code: code } }
      end

      assert InviteCode.exists?(token: code)
    end
  end

  test "signup is blocked when onboarding is closed" do
    with_self_hosting do
      Setting.stubs(:onboarding_state).returns("closed")

      assert_no_difference "User.count" do
        post registration_url, params: { user: { email: "john@example.com", password: "Password1!" } }
      end
      assert_redirected_to new_session_path
    end
  end

  test "an invitation used by a concurrent signup is not used twice" do
    invitation = invitations(:one)
    # Another signup claimed it between the lookup and the save
    Invitation.any_instance.stubs(:claim_for_signup!).returns(false)

    assert_no_difference [ "User.count", "Family.count" ] do
      post registration_url, params: { user: { email: invitation.email, password: "Password1!", invitation: invitation.token } }
    end
    assert_redirected_to new_registration_path
  end

  test "signup through an invitation joins the inviting family and marks it accepted" do
    invitation = invitations(:one)

    assert_difference "User.count", +1 do
      post registration_url, params: { user: { email: invitation.email, password: "Password1!", invitation: invitation.token } }
    end

    assert_redirected_to root_url
    assert_equal invitation.family, User.find_by(email: invitation.email).family
    assert invitation.reload.accepted_at.present?
  end
end
