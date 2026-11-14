require "test_helper"

class OnboardableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:empty)
  end

  test "must complete onboarding before any other action" do
    @user.update!(onboarded_at: nil)

    get root_path
    assert_redirected_to onboarding_path
  end

  test "onboarded user can visit dashboard" do
    @user.update!(onboarded_at: 1.day.ago)

    get root_path
    assert_response :success
  end

  test "a user who has not finished onboarding can sign out" do
    @user.update!(onboarded_at: nil)

    delete session_path(@user.sessions.order(:created_at).last)

    assert_redirected_to new_session_path
    get root_path
    assert_redirected_to new_session_path
  end
end
