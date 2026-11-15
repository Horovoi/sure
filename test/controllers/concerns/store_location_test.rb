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

  test "a short return_to is stored unchanged" do
    get settings_profile_path(return_to: "/transactions?q[search]=coffee")
    assert_equal "/transactions?q[search]=coffee", session[:return_to]
  end

  test "a return_to over the cap with a query keeps only its path" do
    long_query = Array.new(200) { |i| "q[account_ids][]=#{i}" }.join("&")
    return_to = "/transactions?#{long_query}"
    assert_operator return_to.bytesize, :>, StoreLocation::MAX_STORED_RETURN_TO_BYTES

    get settings_profile_path(return_to: return_to)

    assert_equal "/transactions", session[:return_to]
  end

  test "a bare path over the cap stores nothing and clears the older value" do
    get settings_profile_path(return_to: "/accounts")
    assert_equal "/accounts", session[:return_to]

    get settings_profile_path(return_to: "/#{"a" * (StoreLocation::MAX_STORED_RETURN_TO_BYTES + 1)}")

    assert_nil session[:return_to]
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
