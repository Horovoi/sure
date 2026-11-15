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

  test "throttling is enabled only in production and staging" do
    refute Rack::Attack.enabled, "the test environment must not be throttled"
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

  test "rack attack is in the middleware stack exactly once" do
    # Two copies would count every request twice and halve each limit.
    assert_equal 1, Rails.application.middleware.count { |middleware| middleware.klass == Rack::Attack }
  end

  test "login throttle covers format suffixes and router path spellings" do
    throttle = Rack::Attack.throttles["login/ip"]

    [ "/sessions", "/sessions.json", "/sessions/", "//sessions", "/api/v1/auth/login.json", "/registration.json" ].each do |path|
      assert_equal "10.0.0.7", throttle.block.call(attack_request(path, method: "POST")), "#{path} should be throttled"
    end
  end

  test "mfa throttle covers a format suffix" do
    assert_equal "10.0.0.7", Rack::Attack.throttles["mfa/ip"].block.call(attack_request("/mfa/verify.json", method: "POST"))
  end

  test "oauth token throttle covers a format suffix" do
    assert_equal "10.0.0.7", Rack::Attack.throttles["oauth/token"].block.call(attack_request("/oauth/token.json", method: "POST"))
  end

  test "password changes are throttled per IP" do
    throttle = Rack::Attack.throttles["password_change/ip"]
    assert throttle

    assert_equal "10.0.0.7", throttle.block.call(attack_request("/password", method: "PATCH"))
    assert_equal "10.0.0.7", throttle.block.call(attack_request("/password", method: "PUT"))
    assert_equal "10.0.0.7", throttle.block.call(attack_request("/password.json", method: "PATCH"))
    assert_nil throttle.block.call(attack_request("/password/edit", method: "GET"))
  end

  test "password reset requests are throttled per IP" do
    throttle = Rack::Attack.throttles["password_reset/ip"]
    assert throttle

    assert_equal "10.0.0.7", throttle.block.call(attack_request("/password_reset", method: "POST"))
    assert_equal "10.0.0.7", throttle.block.call(attack_request("/password_reset.json", method: "POST"))
  end

  test "credential throttles ignore pages, other paths and look-alike paths" do
    requests = [
      attack_request("/sessions/new", method: "GET"),
      attack_request("/transactions?currency_code=UAH", method: "GET"),
      attack_request("/sessionsx", method: "POST"),
      attack_request("/sessions.json/x", method: "POST")
    ]

    %w[login/ip mfa/ip oauth/token password_change/ip password_reset/ip].each do |name|
      requests.each do |request|
        assert_nil Rack::Attack.throttles[name].block.call(request), "#{name} should ignore #{request.request_method} #{request.fullpath}"
      end
    end
  end

  private
    def attack_request(path, method:)
      Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "10.0.0.7"))
    end
end
