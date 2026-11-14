require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "lists tools for the configured user" do
    with_mcp_env do
      post_jsonrpc "tools/list"

      assert_response :success
      assert JSON.parse(response.body).dig("result", "tools").any?
    end
  end

  test "rejects a wrong token" do
    with_mcp_env do
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: { "Authorization" => "Bearer wrong", "Content-Type" => "application/json" }

      assert_response :unauthorized
    end
  end

  test "refuses tool calls when the user turned AI off" do
    @user.update!(ai_enabled: false)

    with_mcp_env do
      post_jsonrpc "tools/call", params: { name: "get_accounts", arguments: {} }

      assert_response :forbidden
    end
  end

  private
    def with_mcp_env(&block)
      with_env_overrides(MCP_API_TOKEN: "mcp-test-token", MCP_USER_EMAIL: @user.email, &block)
    end

    def post_jsonrpc(method, params: nil)
      body = { jsonrpc: "2.0", id: 1, method: method }
      body[:params] = params if params

      post "/mcp", params: body.to_json,
        headers: { "Authorization" => "Bearer mcp-test-token", "Content-Type" => "application/json" }
    end
end
