require "test_helper"

# Wire contract of /mcp (MCP 2026-07-28, stateless, tools only). These tests talk HTTP and JSON-RPC, not the SDK,
# so they also guard upgrades of the mcp gem.
class McpControllerTest < ActionDispatch::IntegrationTest
  VERSION = "2026-07-28".freeze
  TOKEN = "mcp-test-token".freeze

  setup do
    @user = users(:family_admin)
  end

  # --- server/discover ---------------------------------------------------------------------------------------

  test "server/discover names the supported version, cache hints and server info" do
    with_mcp_env do
      mcp_post "server/discover"

      assert_response :success
      result = rpc_result
      assert_equal [ VERSION ], result["supportedVersions"]
      assert_equal "complete", result["resultType"]
      assert_equal Mcp::ServerBuilder::LIST_TTL_MS, result["ttlMs"]
      assert_equal "private", result["cacheScope"]
      assert_equal "sure", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
      assert_equal Sure.version.to_s, result.dig("_meta", "io.modelcontextprotocol/serverInfo", "version")
      assert result["capabilities"].key?("tools")
      assert_match "National Bank of Ukraine", result["instructions"]
    end
  end

  # --- tools/list --------------------------------------------------------------------------------------------

  test "tools/list returns every tool in a stable order with cache hints and annotations" do
    with_mcp_env do
      mcp_post "tools/list"

      assert_response :success
      result = rpc_result
      assert_equal "complete", result["resultType"]
      assert_equal Mcp::ServerBuilder::LIST_TTL_MS, result["ttlMs"]
      assert_equal "private", result["cacheScope"]

      tools = result["tools"]
      assert_equal Assistant.function_classes.map(&:name), tools.map { |tool| tool["name"] }

      accounts = tools.find { |tool| tool["name"] == "get_accounts" }
      assert_equal "Get accounts", accounts["title"]
      assert_equal "object", accounts.dig("inputSchema", "type")
      assert_equal({ "destructiveHint" => false, "idempotentHint" => true, "openWorldHint" => false, "readOnlyHint" => true },
        accounts["annotations"])

      import = tools.find { |tool| tool["name"] == "import_bank_statement" }
      assert_equal false, import.dig("annotations", "readOnlyHint")
      assert_equal true, import.dig("annotations", "openWorldHint")

      first_order = tools.map { |tool| tool["name"] }
      mcp_post "tools/list"
      assert_equal first_order, rpc_result["tools"].map { |tool| tool["name"] }
    end
  end

  test "MCP and the in-app chat share one tool list in one order" do
    chat_functions = Assistant.config_for(chats(:two))[:functions]

    with_mcp_env do
      mcp_post "tools/list"

      assert_equal chat_functions.map(&:name), rpc_result["tools"].map { |tool| tool["name"] }
    end
  end

  # --- tools/call --------------------------------------------------------------------------------------------

  test "tools/call returns structured content and the same JSON as text" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }

      assert_response :success
      result = rpc_result
      assert_equal "complete", result["resultType"]
      assert_equal false, result["isError"]
      assert result["structuredContent"]["accounts"].any?
      assert_equal result["structuredContent"], JSON.parse(result.dig("content", 0, "text"))
    end
  end

  test "a failing tool returns a sanitised error result" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).raises(RuntimeError, "PG::Error at 10.0.0.5 SELECT secret")

    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }

      assert_response :success
      result = rpc_result
      assert_equal true, result["isError"]
      assert_equal "get_accounts failed unexpectedly", result.dig("structuredContent", "error")
      assert result.dig("structuredContent", "hint").present?
      refute_match "secret", response.body
      refute_match "10.0.0.5", response.body
    end
  end

  test "a record that is not found hides the SQL" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call)
      .raises(ActiveRecord::RecordNotFound, %(Couldn't find Account [WHERE "accounts"."family_id" = $1]))

    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }

      assert_equal true, rpc_result["isError"]
      refute_match "WHERE", response.body
    end
  end

  test "an unknown tool is a -32602 protocol error" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "drop_everything", arguments: {} }

      assert_response :bad_request
      assert_equal(-32602, rpc_error["code"])
    end
  end

  test "an unknown method is 404 with -32601" do
    with_mcp_env do
      mcp_post "resources/frobnicate"

      assert_response :not_found
      assert_equal(-32601, rpc_error["code"])
    end
  end

  test "tools run in the family time zone" do
    @user.family.update!(timezone: "Europe/Kyiv")

    with_mcp_env do
      Time.use_zone("UTC") do
        # 23:30 UTC on 14 November is already 15 November in Kyiv
        travel_to Time.utc(2026, 11, 14, 23, 30) do
          mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }

          assert_response :success
          assert_equal "2026-11-15", rpc_result.dig("structuredContent", "as_of_date")
          assert_equal "UTC", Time.zone.name
        end
      end
    end
  end

  # --- Header and envelope rules -----------------------------------------------------------------------------

  test "a missing Mcp-Method header is 400 with -32020" do
    with_mcp_env do
      mcp_post "tools/list", headers: { "Mcp-Method" => nil }

      assert_response :bad_request
      assert_equal(-32020, rpc_error["code"])
    end
  end

  test "an Mcp-Name header that does not match the tool is 400 with -32020" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }, headers: { "Mcp-Name" => "get_transactions" }

      assert_response :bad_request
      assert_equal(-32020, rpc_error["code"])
    end
  end

  test "a Base64 Mcp-Name header is decoded before it is compared" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }, headers: { "Mcp-Name" => base64_header("get_accounts") }
      assert_response :success
      assert_equal false, rpc_result["isError"]

      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }, headers: { "Mcp-Name" => base64_header("get_holdings") }
      assert_response :bad_request
      assert_equal(-32020, rpc_error["code"])
    end
  end

  test "a header version that differs from the _meta version is 400 with -32020" do
    with_mcp_env do
      mcp_post "tools/list", meta: envelope.merge("io.modelcontextprotocol/protocolVersion" => "2025-11-25")

      assert_response :bad_request
      assert_equal(-32020, rpc_error["code"])
    end
  end

  test "a request without the _meta protocol version is 400 with -32602" do
    with_mcp_env do
      mcp_post "tools/list", meta: {}

      assert_response :bad_request
      assert_equal(-32602, rpc_error["code"])
    end
  end

  test "an unsupported protocol version is 400 with -32022 and the supported list" do
    with_mcp_env do
      [ "2025-06-18", "2027-01-01" ].each do |version|
        mcp_post "tools/list", headers: { "MCP-Protocol-Version" => version }

        assert_response :bad_request
        assert_equal(-32022, rpc_error["code"])
        assert_equal [ VERSION ], rpc_error.dig("data", "supported")
      end
    end
  end

  test "a request without MCP-Protocol-Version is 400 with -32022" do
    with_mcp_env do
      mcp_post "tools/list", headers: { "MCP-Protocol-Version" => nil }

      assert_response :bad_request
      assert_equal(-32022, rpc_error["code"])
      assert_equal [ VERSION ], rpc_error.dig("data", "supported")
    end
  end

  test "a legacy initialize is 400 with -32022 and the supported list" do
    with_mcp_env do
      [ VERSION, nil ].each do |header_version|
        post "/mcp",
          params: { jsonrpc: "2.0", id: 1, method: "initialize",
                    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "old", version: "1" } } }.to_json,
          headers: base_headers("initialize").merge("MCP-Protocol-Version" => header_version).compact

        assert_response :bad_request
        assert_equal(-32022, rpc_error["code"])
        assert_equal [ VERSION ], rpc_error.dig("data", "supported")
        assert_equal 1, response.parsed_body["id"]
      end
    end
  end

  test "a notification is accepted with 202 and no body" do
    with_mcp_env do
      post "/mcp",
        params: { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 7 } }.to_json,
        headers: base_headers("notifications/cancelled")

      assert_response :accepted
      assert_equal "", response.body
    end
  end

  test "a body that is not JSON is 400 with -32700" do
    with_mcp_env do
      post "/mcp", params: "{not json", headers: base_headers("tools/list")

      assert_response :bad_request
      assert_equal(-32700, rpc_error["code"])
    end
  end

  test "GET and DELETE are 405 with Allow: POST" do
    with_mcp_env do
      get "/mcp", headers: auth_header
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]

      delete "/mcp", headers: auth_header
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]
    end
  end

  test "an Mcp-Session-Id header is ignored and never echoed" do
    with_mcp_env do
      mcp_post "tools/list", headers: { "Mcp-Session-Id" => "stale-session", "Last-Event-ID" => "42" }

      assert_response :success
      assert rpc_result["tools"].any?
      assert_nil response.headers["Mcp-Session-Id"]
    end
  end

  # --- Origin and authentication -----------------------------------------------------------------------------

  test "a foreign Origin is 403" do
    with_mcp_env do
      mcp_post "tools/list", headers: { "Origin" => "http://evil.example" }

      assert_response :forbidden
    end
  end

  test "no Origin and the same Origin are accepted" do
    with_mcp_env do
      mcp_post "tools/list"
      assert_response :success

      mcp_post "tools/list", headers: { "Origin" => "http://www.example.com" }
      assert_response :success
    end
  end

  test "a wrong or missing token is 401 with a Bearer challenge" do
    with_mcp_env do
      [ "Bearer wrong", "Bearer", nil ].each do |authorization|
        mcp_post "tools/list", headers: { "Authorization" => authorization }

        assert_response :unauthorized
        assert_equal 'Bearer realm="sure"', response.headers["WWW-Authenticate"]
      end
    end
  end

  test "the endpoint is unavailable without a configured token" do
    with_env_overrides(MCP_API_TOKEN: nil, MCP_USER_EMAIL: @user.email) do
      mcp_post "tools/list"

      assert_response :service_unavailable
    end
  end

  test "the endpoint is unavailable when the configured user is missing" do
    with_env_overrides(MCP_API_TOKEN: TOKEN, MCP_USER_EMAIL: "nobody@example.com") do
      mcp_post "tools/list"

      assert_response :service_unavailable
    end
  end

  test "the user's AI switch does not block the static token" do
    @user.update!(ai_enabled: false)

    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }

      assert_response :success
      assert_equal false, rpc_result["isError"]
    end
  end

  private
    def with_mcp_env(&block)
      with_env_overrides(MCP_API_TOKEN: TOKEN, MCP_USER_EMAIL: @user.email, &block)
    end

    def envelope
      {
        "io.modelcontextprotocol/protocolVersion" => VERSION,
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => { "name" => "claude-code", "version" => "2.1.325" }
      }
    end

    def auth_header
      { "Authorization" => "Bearer #{TOKEN}" }
    end

    def base_headers(method)
      auth_header.merge(
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
        "MCP-Protocol-Version" => VERSION,
        "Mcp-Method" => method
      )
    end

    # Posts a modern request the way a 2026-07-28 client does. Pass a header as nil to leave it out.
    def mcp_post(method, params: {}, meta: envelope, headers: {}, id: 1)
      body = { jsonrpc: "2.0", id: id, method: method, params: params.merge(_meta: meta) }
      request_headers = base_headers(method)
      request_headers["Mcp-Name"] = params[:name] if params[:name]

      post "/mcp", params: body.to_json, headers: request_headers.merge(headers).compact
    end

    def base64_header(value)
      "=?base64?#{[ value ].pack("m0")}?="
    end

    def rpc_result
      response.parsed_body.fetch("result")
    end

    def rpc_error
      response.parsed_body.fetch("error")
    end
end
