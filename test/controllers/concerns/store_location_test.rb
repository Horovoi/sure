require "test_helper"

class StoreLocationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "stores a relative return_to path" do
    get settings_profile_path(return_to: "/accounts")
    assert_equal "/accounts", session[:return_to]
  end

  test "ignores return_to values that are not paths on this site" do
    [ "javascript:alert(1)", "https://evil.example", "//evil.example", "/\\evil.example", "accounts", "/a\nb" ].each do |value|
      get settings_profile_path(return_to: value)
      assert_nil session[:return_to], "expected #{value.inspect} to be rejected"
    end
  end

  test "sanitize_return_to accepts only site-relative paths" do
    controller = ApplicationController.new

    assert_equal "/accounts?tab=all", controller.send(:sanitize_return_to, "/accounts?tab=all")
    assert_nil controller.send(:sanitize_return_to, "//evil.example/x")
    assert_nil controller.send(:sanitize_return_to, "javascript:alert(1)")
    assert_nil controller.send(:sanitize_return_to, nil)
    assert_nil controller.send(:sanitize_return_to, [ "/accounts" ])
  end
end
