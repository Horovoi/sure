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

  test "tools run in the family time zone" do
    @user.family.update!(timezone: "Europe/Kyiv")

    with_mcp_env do
      Time.use_zone("UTC") do
        # 23:30 UTC on 14 November is already 15 November in Kyiv
        travel_to Time.utc(2026, 11, 14, 23, 30) do
          post_jsonrpc "tools/call", params: { name: "get_accounts", arguments: {} }

          assert_response :success
          result = JSON.parse(JSON.parse(response.body).dig("result", "content", 0, "text"))
          assert_equal "2026-11-15", result["as_of_date"]
          assert_equal "UTC", Time.zone.name
        end
      end
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
