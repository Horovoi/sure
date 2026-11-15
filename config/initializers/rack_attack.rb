# frozen_string_literal: true

class Rack::Attack
  SUSPICIOUS_USER_AGENTS = [
    /sqlmap/i,
    /nmap/i,
    /nikto/i,
    /masscan/i
  ].freeze

  # Throttle and block only in production and staging (the middleware stays installed)
  self.enabled = Rails.env.production? || Rails.env.staging?

  # Throttle requests to the OAuth token endpoint
  throttle("oauth/token", limit: 10, period: 1.minute) do |request|
    request.ip if request.path == "/oauth/token"
  end

  # Throttle the MFA code step (and MFA disable, which also takes a code) to
  # stop brute-forcing 6-digit codes. The app is reachable from the LAN.
  MFA_CODE_PATHS = %w[/mfa/verify /mfa/disable].freeze
  throttle("mfa/ip", limit: 5, period: 1.minute) do |request|
    request.ip if MFA_CODE_PATHS.include?(request.path) && (request.post? || request.delete?)
  end

  # Throttle password logins and signups (web and API)
  LOGIN_PATHS = %w[/sessions /registration /api/v1/auth/login /api/v1/auth/signup /oidc_account/create_link].freeze
  throttle("login/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && LOGIN_PATHS.include?(request.path)
  end

  # Throttle admin endpoints to prevent brute-force attacks
  # More restrictive than general API limits since admin access is sensitive
  throttle("admin/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/admin/")
  end

  # Determine limits based on self-hosted mode
  self_hosted = Rails.application.config.app_mode.self_hosted?

  # Throttle API requests per access token
  throttle("api/requests", limit: self_hosted ? 10_000 : 100, period: 1.hour) do |request|
    if request.path.start_with?("/api/")
      # Extract access token from Authorization header
      auth_header = request.get_header("HTTP_AUTHORIZATION")
      if auth_header&.start_with?("Bearer ")
        token = auth_header.split(" ").last
        "api_token:#{Digest::SHA256.hexdigest(token)}"
      else
        # Fall back to IP-based limiting for unauthenticated requests
        "api_ip:#{request.ip}"
      end
    end
  end

  # More permissive throttling for API requests by IP (for development/testing)
  throttle("api/ip", limit: self_hosted ? 20_000 : 200, period: 1.hour) do |request|
    request.ip if request.path.start_with?("/api/")
  end

  # w1-budrec: the subscriptions iCal feed has no session; its token is in the
  # path, so guessing tokens is throttled. Calendar apps poll it a few times an hour.
  throttle("subscriptions_feed/ip", limit: 30, period: 1.minute) do |request|
    request.ip if request.get? && request.path.start_with?("/feeds/subscriptions/")
  end

  # Block requests that appear to be malicious
  blocklist("block malicious requests") do |request|
    # Block requests with suspicious user agents
    user_agent = request.user_agent
    SUSPICIOUS_USER_AGENTS.any? { |pattern| user_agent =~ pattern } if user_agent
  end

  # Configure response for throttled requests
  self.throttled_responder = lambda do |request|
    [
      429, # status
      {
        "Content-Type" => "application/json",
        "Retry-After" => "60"
      },
      [ { error: "Rate limit exceeded. Try again later." }.to_json ]
    ]
  end

  # Configure response for blocked requests
  self.blocklisted_responder = lambda do |request|
    [
      403, # status
      { "Content-Type" => "application/json" },
      [ { error: "Request blocked." }.to_json ]
    ]
  end
end
