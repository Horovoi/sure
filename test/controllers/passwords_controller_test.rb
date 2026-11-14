require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_session = @user.sessions.create!
    sign_in @user
  end

  test "changing the password signs out other sessions but keeps this one" do
    patch password_url, params: { user: {
      password: "NewPassword1!",
      password_confirmation: "NewPassword1!",
      password_challenge: user_password_test
    } }

    assert_redirected_to root_url
    assert_not Session.exists?(@other_session.id)
    assert_equal 1, @user.sessions.count

    get root_url
    assert_response :success
  end

  test "a failed password change keeps other sessions" do
    patch password_url, params: { user: {
      password: "NewPassword1!",
      password_confirmation: "NewPassword1!",
      password_challenge: "wrong"
    } }

    assert_response :unprocessable_entity
    assert Session.exists?(@other_session.id)
    assert @user.reload.authenticate(user_password_test), "password must not change without the current one"
  end

  test "a mismatched confirmation is rejected" do
    patch password_url, params: { user: {
      password: "NewPassword1!",
      password_confirmation: "Different1!",
      password_challenge: user_password_test
    } }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate(user_password_test)
  end
end
