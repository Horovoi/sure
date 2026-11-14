require "test_helper"

class InviteCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    @code = InviteCode.create!
  end

  test "super admin can generate, list and delete invite codes" do
    sign_in users(:sure_support_staff)

    assert_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end

    get invite_codes_url
    assert_response :success
    assert_includes response.body, @code.token

    assert_difference("InviteCode.count", -1) do
      delete invite_code_url(@code)
    end
  end

  test "family admin who is not a super admin cannot generate invite codes" do
    sign_in users(:family_admin)

    assert_no_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end
    assert_redirected_to settings_hosting_path
  end

  test "non-super-admin cannot list invite codes" do
    sign_in users(:family_member)

    get invite_codes_url
    assert_redirected_to settings_hosting_path
    assert_not_includes response.body, @code.token
  end

  test "non-super-admin cannot delete invite codes" do
    sign_in users(:family_admin)

    assert_no_difference("InviteCode.count") do
      delete invite_code_url(@code)
    end
  end
end
