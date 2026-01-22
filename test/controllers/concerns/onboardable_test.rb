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
end
