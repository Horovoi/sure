# frozen_string_literal: true

require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  test "rack attack is configured" do
    # Verify Rack::Attack is enabled in middleware stack
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Attack, "Rack::Attack should be in middleware stack"
  end

  test "oauth token endpoint has rate limiting configured" do
    # Test that the throttle is configured (we don't need to trigger it)
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "oauth/token", "OAuth token endpoint should have rate limiting"
  end

  test "api requests have rate limiting configured" do
    # Test that API rate limiting is configured
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "api/requests", "API requests should have rate limiting"
  end

  test "mfa code steps are throttled per IP" do
    throttle = Rack::Attack.throttles["mfa/ip"]
    assert throttle, "MFA verification should have rate limiting"

    verify = Rack::Attack::Request.new(Rack::MockRequest.env_for("/mfa/verify", method: "POST", "REMOTE_ADDR" => "10.0.0.5"))
    disable = Rack::Attack::Request.new(Rack::MockRequest.env_for("/mfa/disable", method: "DELETE", "REMOTE_ADDR" => "10.0.0.5"))
    page = Rack::Attack::Request.new(Rack::MockRequest.env_for("/mfa/verify", method: "GET", "REMOTE_ADDR" => "10.0.0.5"))

    assert_equal "10.0.0.5", throttle.block.call(verify)
    assert_equal "10.0.0.5", throttle.block.call(disable)
    assert_nil throttle.block.call(page)
  end

  test "password logins are throttled per IP" do
    throttle = Rack::Attack.throttles["login/ip"]
    assert throttle

    login = Rack::Attack::Request.new(Rack::MockRequest.env_for("/sessions", method: "POST", "REMOTE_ADDR" => "10.0.0.6"))
    assert_equal "10.0.0.6", throttle.block.call(login)
  end
end
