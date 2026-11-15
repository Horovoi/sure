# The /mcp endpoint: MCP protocol 2026-07-28 only, stateless, tools only, served by the official "mcp" gem.
# Claude Code connects with the static MCP_API_TOKEN; every request is self-contained (no initialize handshake,
# no Mcp-Session-Id) and runs as the MCP_USER_EMAIL user in the family time zone.
class McpController < ApplicationController
  SUPPORTED_PROTOCOL_VERSIONS = MCP::Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS
  MAX_REQUEST_BYTES = 1.megabyte
  JSON_RPC_INVALID_REQUEST = -32600
  JSON_RPC_PARSE_ERROR = -32700

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  # Order matters: who is calling, then whether this endpoint serves them, then whether the request is one this
  # server speaks. The time zone wraps only after authentication, when Current knows the family.
  before_action :authenticate_mcp_token!
  before_action :set_mcp_user
  before_action :require_mcp_enabled!
  before_action :verify_origin!
  before_action :drop_session_headers
  before_action :require_modern_protocol!, if: -> { request.post? }
  skip_around_action :switch_timezone
  around_action :switch_timezone

  # Shared before_actions read params, which makes Rails parse the JSON body before the SDK sees it. A body that is
  # not JSON then gets the JSON-RPC parse error the SDK would give.
  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { jsonrpc: "2.0", error: { code: JSON_RPC_PARSE_ERROR, message: "Parse error" } }, status: :bad_request
  end

  def handle
    return render_method_not_allowed unless request.post?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, headers, body = transport.handle_request(rewound_request)
    render_transport_response(status, headers, body)
  ensure
    log_request(started_at) if started_at
  end

  private
    def transport
      MCP::Server::Transports::StreamableHTTPTransport.new(
        Mcp::ServerBuilder.build(credential),
        stateless: true,
        serve_subscriptions_listen: false,
        # The SDK's check allows only loopback Host values; production is reached over the LAN on purpose.
        # verify_origin! does the Origin half of that check instead.
        dns_rebinding_protection: false,
        max_request_bytes: MAX_REQUEST_BYTES
      )
    end

    def credential
      @credential ||= Mcp::Credential.static(@mcp_user, client_name: client_name)
    end

    # Rails may have read the body already (raw_post, params parsing); the SDK reads it again
    def rewound_request
      request.body.rewind if request.body.respond_to?(:rewind)
      request
    end

    def render_transport_response(status, headers, body)
      headers.each { |name, value| response.headers[name] = value unless name.to_s.casecmp?("content-type") }
      text = body.respond_to?(:join) ? body.join : body.to_s

      if text.empty?
        head status
      else
        render body: text, status: status, content_type: headers["content-type"] || "application/json"
      end
    end

    # --- Authentication -------------------------------------------------------------------------------------

    def authenticate_mcp_token!
      expected = ENV["MCP_API_TOKEN"].to_s
      if expected.empty?
        render_gate_error(:service_unavailable, "MCP endpoint not configured")
        return
      end

      # Comparing digests keeps the comparison constant-time whatever the length of the token sent
      token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1].to_s.strip
      return if token.present? && ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(token), Digest::SHA256.hexdigest(expected)
      )

      response.headers["WWW-Authenticate"] = 'Bearer realm="sure"'
      render_gate_error(:unauthorized, "Unauthorized")
    end

    # The static token acts as one configured user. The user's AI switch gates only the in-app chat, not this
    # endpoint (decision 13).
    def set_mcp_user
      email = ENV["MCP_USER_EMAIL"].presence
      @mcp_user = User.find_by(email: email) if email

      unless @mcp_user&.active?
        render_gate_error(:service_unavailable, "MCP user not configured")
        return
      end

      Current.session = Session.ephemeral_for(@mcp_user, request)
    end

    # Settings > Self-hosting can turn the static-token clients off (decision 13). It runs after authentication,
    # so only a caller holding the token learns the endpoint is switched off. The in-app chat's per-turn token
    # (Claude chat adapter) is gated by the user's ai_enabled instead and must skip this check.
    def require_mcp_enabled!
      return if !credential.static? || Setting.mcp_enabled

      render_gate_error(:forbidden, "MCP is turned off in Settings > Self-Hosting")
    end

    # --- Transport rules ------------------------------------------------------------------------------------

    # A browser page on another site must not drive the endpoint (DNS rebinding). Non-browser clients send no
    # Origin and pass; a same-origin Origin passes.
    def verify_origin!
      origin = request.headers["Origin"]
      return if origin.blank? || origin.casecmp?(request.base_url)

      render_gate_error(:forbidden, "Forbidden: Origin not allowed")
    end

    # Sessions and stream resumption do not exist in 2026-07-28: the headers are ignored, never echoed. The SDK
    # would refuse a request that carries Mcp-Session-Id, so they are removed before it sees the request.
    def drop_session_headers
      request.env.delete("HTTP_MCP_SESSION_ID")
      request.env.delete("HTTP_LAST_EVENT_ID")
    end

    # This server speaks 2026-07-28 only. A legacy client (initialize handshake, or no MCP-Protocol-Version
    # header) is told which versions are supported, as the spec asks of a modern-only server.
    def require_modern_protocol!
      version = request.headers["MCP-Protocol-Version"].to_s
      return if SUPPORTED_PROTOCOL_VERSIONS.include?(version) && rpc_body&.dig("method") != "initialize"

      render json: {
        jsonrpc: "2.0",
        id: echoable_id(rpc_body&.dig("id")),
        error: {
          code: MCP::ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
          message: "Unsupported protocol version",
          data: { supported: SUPPORTED_PROTOCOL_VERSIONS, requested: version.presence }
        }
      }.compact, status: :bad_request
    end

    def render_method_not_allowed
      response.headers["Allow"] = "POST"
      render_gate_error(:method_not_allowed, "Method not allowed")
    end

    def render_gate_error(status, message)
      render json: { jsonrpc: "2.0", error: { code: JSON_RPC_INVALID_REQUEST, message: message } }, status: status
    end

    # --- Request body (read for the version gate and the log; the SDK parses it again) ----------------------

    def rpc_body
      return @rpc_body if defined?(@rpc_body)

      @rpc_body = begin
        if request.content_length.to_i > MAX_REQUEST_BYTES
          nil
        else
          parsed = JSON.parse(request.raw_post.to_s)
          parsed.is_a?(Hash) ? parsed : nil
        end
      rescue JSON::ParserError
        nil
      end
    end

    def rpc_params
      params = rpc_body&.dig("params")
      params.is_a?(Hash) ? params : {}
    end

    def client_name
      meta = rpc_params["_meta"]
      return unless meta.is_a?(Hash)

      info = meta[MCP::RequestEnvelope::CLIENT_INFO_META_KEY]
      info["name"].to_s.truncate(100).presence if info.is_a?(Hash)
    end

    def echoable_id(id)
      id if id.is_a?(String) || id.is_a?(Integer)
    end

    def log_request(started_at)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      tool = rpc_params["name"] if rpc_body&.dig("method") == "tools/call"

      Rails.logger.info(
        "MCP #{rpc_body&.dig("method") || "-"}" \
        "#{" tool=#{tool}" if tool} client=#{client_name || "-"} status=#{response.status} duration_ms=#{duration_ms}"
      )
    end
end
