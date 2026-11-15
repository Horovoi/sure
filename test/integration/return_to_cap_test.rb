require "test_helper"

# The session is a 4 KB cookie. Storing a long return_to used to raise
# ActionDispatch::Cookies::CookieOverflow and turn the response into a 500.
class ReturnToCapTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "a return_to with a 3 KB query does not overflow the session cookie" do
    long_query = Array.new(60) { "q[account_ids][]=#{SecureRandom.uuid}" }.join("&")
    return_to = "/transactions?#{long_query}"
    assert_operator return_to.bytesize, :>, 3.kilobytes

    assert_nothing_raised do
      get accounts_path(return_to: return_to)
    end

    assert_response :success
    assert_equal "/transactions", session[:return_to]
  end
end
