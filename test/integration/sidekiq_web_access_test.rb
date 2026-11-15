require "test_helper"

class SidekiqWebAccessTest < ActionDispatch::IntegrationTest
  test "signed-out visitor gets 404" do
    get "/sidekiq"

    assert_response :not_found
  end

  test "family member gets 404" do
    sign_in users(:family_member)

    get "/sidekiq"

    assert_response :not_found
  end

  test "admin who is not a super admin gets 404" do
    sign_in users(:family_admin)

    get "/sidekiq"

    assert_response :not_found
  end

  test "deactivated super admin gets 404" do
    user = users(:sure_support_staff)
    sign_in user
    # Skip the deactivation callbacks (they would also revoke the session); the gate
    # must reject an inactive user even while the session row still exists.
    user.update_column(:active, false)

    get "/sidekiq"

    assert_response :not_found
  end

  test "active super admin can open the dashboard and the cron page" do
    sign_in users(:sure_support_staff)

    get "/sidekiq"
    assert_response :success

    get "/sidekiq/cron"
    assert_response :success
  end

  test "garbage session cookie fails closed" do
    cookies[:session_token] = "not-a-signed-cookie"

    get "/sidekiq"

    assert_response :not_found
  end

  test "the dashboard has no basic auth, even when the old variables are set" do
    with_env_overrides("SIDEKIQ_WEB_USERNAME" => "sure", "SIDEKIQ_WEB_PASSWORD" => "sure") do
      load Rails.root.join("config/initializers/sidekiq.rb")
    end

    basic_auth = Sidekiq::Web.middlewares.select { |args, _block| args.first == Rack::Auth::Basic }
    assert_empty basic_auth
  end
end
