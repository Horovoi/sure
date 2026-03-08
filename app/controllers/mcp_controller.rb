class McpController < ApplicationController
  PROTOCOL_VERSION = "2025-03-26"

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  before_action :authenticate_mcp_token!

  def handle
    body = parse_request_body
    return if performed?

    unless valid_jsonrpc?(body)
      render_jsonrpc_error(body&.dig("id"), -32600, "Invalid Request")
      return
    end

    request_id = body["id"]
    return head(:no_content) unless body.key?("id")

    result = dispatch_jsonrpc(request_id, body["method"], body["params"])
    return if performed?

    render json: { jsonrpc: "2.0", id: request_id, result: result }
  end

  private
    def parse_request_body
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      render_jsonrpc_error(nil, -32700, "Parse error")
      nil
    end

    def valid_jsonrpc?(body)
      body.is_a?(Hash) && body["jsonrpc"] == "2.0" && body["method"].present?
    end

    def dispatch_jsonrpc(request_id, method, params)
      case method
      when "initialize"
        handle_initialize
      when "tools/list"
        handle_tools_list
      when "tools/call"
        handle_tools_call(request_id, params)
      else
        render_jsonrpc_error(request_id, -32601, "Method not found: #{method}")
        nil
      end
    end

    def handle_initialize
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "sure", version: "1.0" }
      }
    end

    def handle_tools_list
      tools = Assistant.function_classes.map do |function_class|
        function = function_class.new(mcp_user)
        {
          name: function.name,
          description: function.description,
          inputSchema: function.params_schema
        }
      end

      { tools: tools }
    end

    def handle_tools_call(request_id, params)
      name = params&.dig("name")
      arguments = params&.dig("arguments") || {}

      function_class = Assistant.function_classes.find { |klass| klass.name == name }
      unless function_class
        render_jsonrpc_error(request_id, -32602, "Unknown tool: #{name}")
        return nil
      end

      result = function_class.new(mcp_user).call(arguments)
      { content: [ { type: "text", text: result.to_json } ] }
    rescue => error
      Rails.logger.error("MCP tools/call error: #{error.message}")
      { content: [ { type: "text", text: { error: error.message }.to_json } ], isError: true }
    end

    def authenticate_mcp_token!
      expected = ENV["MCP_API_TOKEN"].to_s
      unless expected.present?
        render json: { error: "MCP endpoint not configured" }, status: :service_unavailable
        return
      end

      token = request.headers["Authorization"]&.delete_prefix("Bearer ")&.strip.to_s
      unless ActiveSupport::SecurityUtils.secure_compare(token, expected)
        render json: { error: "unauthorized" }, status: :unauthorized
        return
      end

      setup_mcp_user
    end

    def setup_mcp_user
      email = ENV["MCP_USER_EMAIL"].presence
      @mcp_user = User.find_by(email: email) if email.present?

      unless @mcp_user
        render json: { error: "MCP user not configured" }, status: :service_unavailable
        return
      end

      Current.session = @mcp_user.sessions.build(
        user_agent: request.user_agent,
        ip_address: request.ip
      )
    end

    def mcp_user
      @mcp_user
    end

    def render_jsonrpc_error(id, code, message)
      render json: {
        jsonrpc: "2.0",
        id: id,
        error: { code: code, message: message }
      }
    end
end
