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
      assert_equal Sure.build_tag.to_s, result.dig("_meta", "io.modelcontextprotocol/serverInfo", "version")
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

  # --- Settings > Self-hosting switch (decision 13) ----------------------------------------------------------

  test "the MCP switch turned off gives 403 even with the AI switch on" do
    @user.update!(ai_enabled: true)
    Setting.mcp_enabled = false

    with_mcp_env do
      mcp_post "tools/list"

      assert_response :forbidden
      assert_equal McpController::JSON_RPC_INVALID_REQUEST, rpc_error["code"]
    end
  ensure
    Setting.mcp_enabled = true
  end

  test "the MCP switch on serves the static token with the AI switch off" do
    @user.update!(ai_enabled: false)
    Setting.mcp_enabled = true

    with_mcp_env do
      mcp_post "tools/list"

      assert_response :success
      assert rpc_result["tools"].any?
    end
  end

  test "the MCP switch is checked after the token, so a caller without it learns nothing" do
    Setting.mcp_enabled = false

    with_mcp_env do
      mcp_post "tools/list", headers: { "Authorization" => "Bearer wrong" }

      assert_response :unauthorized
    end
  ensure
    Setting.mcp_enabled = true
  end

  # --- Tool scope -----------------------------------------------------------------------------------------

  test "a full-scope credential lists every tool in the fixed order" do
    with_mcp_env do
      mcp_post "tools/list"

      assert_equal Assistant.function_classes_for(:full).map(&:name), rpc_result["tools"].map { |tool| tool["name"] }
    end
  end

  test "a read-scope credential lists no write tool and cannot call one" do
    Mcp::Credential.stubs(:static).returns(Mcp::Credential.new(user: @user, kind: :static, scope: :read))

    with_mcp_env do
      mcp_post "tools/list"

      names = rpc_result["tools"].map { |tool| tool["name"] }
      assert_equal Assistant.function_classes_for(:read).map(&:name), names
      assert_not_includes names, "import_bank_statement"
      assert(rpc_result["tools"].all? { |tool| tool.dig("annotations", "readOnlyHint") })

      mcp_post "tools/call", params: { name: "import_bank_statement", arguments: { pdf_import_id: SecureRandom.uuid } }

      assert_response :bad_request
      assert_equal(-32602, rpc_error["code"])
    end
  end

  test "a tool that refuses its arguments returns an error result" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_valuations", arguments: { account_id: "not-a-uuid" } }

      assert_response :success
      assert_equal true, rpc_result["isError"]
      assert_equal "invalid_account_id", rpc_result.dig("structuredContent", "error")
    end
  end

  # --- Tool-call audit -------------------------------------------------------------------------------------

  test "tools/call writes an mcp audit row with the clientInfo name" do
    with_mcp_env do
      assert_difference -> { AiToolAudit.count }, 1 do
        mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }
      end
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal "mcp", audit.source
    assert_equal "claude-code", audit.client_name
    assert_equal "get_accounts", audit.tool_name
    assert_equal @user, audit.user
    assert_equal @user.family, audit.family
    assert_nil audit.assistant_message_id
    assert_equal "ok", audit.status
  end

  test "a failing tools/call is audited as an error" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).raises(RuntimeError, "boom")

    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal "get_accounts failed unexpectedly", audit.error_message
  end

  test "tools/list, discover and refused calls write no audit row" do
    with_mcp_env do
      assert_no_difference -> { AiToolAudit.count } do
        mcp_post "tools/list"
        mcp_post "server/discover"
        mcp_post "tools/call", params: { name: "drop_everything", arguments: {} }
      end
    end
  end

  # --- Write tools ------------------------------------------------------------------------------------------

  test "the full-scope tools/list has the write tools with annotations from their tags" do
    with_mcp_env do
      mcp_post "tools/list"

      tools = rpc_result["tools"].index_by { |tool| tool["name"] }
      %w[create_transaction update_transaction delete_transaction create_category update_category create_tag update_tag
         set_opening_balance record_balance get_uncategorized_transactions].each { |name| assert tools.key?(name), name }

      assert_equal({ "destructiveHint" => true, "idempotentHint" => false, "openWorldHint" => false, "readOnlyHint" => false },
        tools["delete_transaction"]["annotations"])
      assert_equal true, tools["update_transaction"].dig("annotations", "idempotentHint")
      assert_equal false, tools["create_transaction"].dig("annotations", "idempotentHint")
      assert_equal true, tools["record_balance"].dig("annotations", "destructiveHint")
      assert_equal true, tools["get_uncategorized_transactions"].dig("annotations", "readOnlyHint")
    end
  end

  test "a read-scope credential cannot call create_transaction" do
    Mcp::Credential.stubs(:static).returns(Mcp::Credential.new(user: @user, kind: :static, scope: :read))

    with_mcp_env do
      mcp_post "tools/call", params: { name: "create_transaction", arguments: { account_id: accounts(:depository).id, date: Date.current.iso8601, amount: 1, name: "x" } }

      assert_response :bad_request
      assert_equal(-32602, rpc_error["code"])
    end
  end

  test "tools/call update_transaction changes it and audits the ids and the state before" do
    transaction = transactions(:one)

    with_mcp_env do
      mcp_post "tools/call", params: { name: "update_transaction", arguments: { id: transaction.id, notes: "Updated through MCP" } }

      assert_response :success
      assert_equal false, rpc_result["isError"]
    end

    assert_equal "Updated through MCP", transaction.reload.entry.notes
    audit = AiToolAudit.order(:created_at).last
    assert_equal "update_transaction", audit.tool_name
    assert_equal "write", audit.scope_tag
    assert_equal "Transaction", audit.result_record_type
    assert_equal [ transaction.id ], audit.result_record_ids
    assert_nil audit.audit_before["notes"]
  end

  test "create_transaction with the same external_id twice creates one entry" do
    arguments = { account_id: accounts(:depository).id, date: Date.current.iso8601, amount: 12.5, name: "Coffee", external_id: "mcp-test-1" }

    with_mcp_env do
      assert_difference -> { Entry.count }, 1 do
        mcp_post "tools/call", params: { name: "create_transaction", arguments: arguments }
        mcp_post "tools/call", params: { name: "create_transaction", arguments: arguments }, id: 2
      end

      assert_equal false, rpc_result.dig("structuredContent", "created")
    end
  end

  # --- Subscription tools ----------------------------------------------------------------------------------

  SUBSCRIPTION_WRITE_TOOLS = %w[create_subscription update_subscription review_subscription_suggestion
                                skip_subscription_occurrence record_subscription_charge].freeze

  test "the full-scope tools/list has the subscription read and write tools" do
    with_mcp_env do
      mcp_post "tools/list"

      tools = rpc_result["tools"].index_by { |tool| tool["name"] }
      assert_equal true, tools["get_subscriptions"].dig("annotations", "readOnlyHint")
      SUBSCRIPTION_WRITE_TOOLS.each do |name|
        assert tools.key?(name), name
        assert_equal false, tools[name].dig("annotations", "readOnlyHint"), name
      end
      assert_equal true, tools["update_subscription"].dig("annotations", "idempotentHint")
      assert_not tools.key?("delete_subscription")
    end
  end

  test "a read-scope credential lists get_subscriptions and none of the subscription writes" do
    Mcp::Credential.stubs(:static).returns(Mcp::Credential.new(user: @user, kind: :static, scope: :read))

    with_mcp_env do
      mcp_post "tools/list"

      names = rpc_result["tools"].map { |tool| tool["name"] }
      assert_includes names, "get_subscriptions"
      SUBSCRIPTION_WRITE_TOOLS.each { |name| assert_not_includes names, name }
    end
  end

  test "the in-app chat gets the subscription write tools too" do
    names = Assistant.config_for(chats(:two))[:functions].map(&:name)

    assert_includes names, "get_subscriptions"
    SUBSCRIPTION_WRITE_TOOLS.each { |name| assert_includes names, name }
  end

  test "tools/call create_subscription audits the new row" do
    with_mcp_env do
      mcp_post "tools/call", params: { name: "create_subscription", arguments: { name: "Gym", amount: 1200, currency: "UAH", expected_day_of_month: 10 } }

      assert_response :success
      assert_equal false, rpc_result["isError"]
    end

    row = @user.family.recurring_transactions.find_by!(name: "Gym")
    assert row.subscription?
    audit = AiToolAudit.order(:created_at).last
    assert_equal "create_subscription", audit.tool_name
    assert_equal "RecurringTransaction", audit.result_record_type
    assert_equal [ row.id ], audit.result_record_ids
  end

  # --- Budget tools ----------------------------------------------------------------------------------------

  test "tools/list has get_budget as a read and update_budget as an idempotent write" do
    with_mcp_env do
      mcp_post "tools/list"

      tools = rpc_result["tools"].index_by { |tool| tool["name"] }
      assert_equal true, tools["get_budget"].dig("annotations", "readOnlyHint")
      assert_equal false, tools["update_budget"].dig("annotations", "readOnlyHint")
      assert_equal true, tools["update_budget"].dig("annotations", "idempotentHint")
      assert_equal [ "amount" ], tools["update_budget"].dig("inputSchema", "required")
    end
  end

  test "a read-scope credential lists get_budget but not update_budget" do
    Mcp::Credential.stubs(:static).returns(Mcp::Credential.new(user: @user, kind: :static, scope: :read))

    with_mcp_env do
      mcp_post "tools/list"

      names = rpc_result["tools"].map { |tool| tool["name"] }
      assert_includes names, "get_budget"
      assert_not_includes names, "update_budget"
    end
  end

  test "tools/call update_budget sets the total and audits the budget with its state before" do
    budget = Budget.find_or_bootstrap(@user.family, start_date: Date.current)
    budget.update!(budgeted_spending: 1000, expected_income: 0)

    with_mcp_env do
      mcp_post "tools/call", params: { name: "update_budget", arguments: { month: budget.start_date.iso8601, amount: 1500 } }

      assert_response :success
      assert_equal false, rpc_result["isError"]
    end

    assert_equal 1500, budget.reload.budgeted_spending
    audit = AiToolAudit.order(:created_at).last
    assert_equal "update_budget", audit.tool_name
    assert_equal "Budget", audit.result_record_type
    assert_equal [ budget.id ], audit.result_record_ids
    assert_equal 1000.0, audit.audit_before["budgeted_spending"]
  end

  # --- Turn token (the in-app Claude chat)-----------------------------------------------------------------
  # The turn token always has scope :full: the chat gets every tool with no approval prompt (owner answer 2).
  # No test may assert that the Claude chat lacks write, delete, rule or transfer tools.

  test "a turn token lists every tool while its turn streams, writes and deletes included" do
    turn = streaming_claude_turn

    mcp_post "tools/list", headers: turn_auth(turn)

    assert_response :success
    names = rpc_result["tools"].map { |tool| tool["name"] }
    assert_equal Assistant.function_classes_for(:full).map(&:name), names
    %w[create_transaction update_transaction delete_transaction record_balance].each { |name| assert_includes names, name }
    %w[apply_rule unmatch_transfer].each do |name|
      assert_includes names, name if Assistant.function_classes.map(&:name).include?(name)
    end
    assert_equal true, rpc_result["tools"].find { |tool| tool["name"] == "delete_transaction" }.dig("annotations", "destructiveHint")
  end

  test "a turn token works without MCP_API_TOKEN and with the MCP switch off" do
    turn = streaming_claude_turn
    Setting.mcp_enabled = false

    with_env_overrides(MCP_API_TOKEN: nil, MCP_USER_EMAIL: nil) do
      mcp_post "tools/list", headers: turn_auth(turn)
    end

    assert_response :success
    assert rpc_result["tools"].any?
  ensure
    Setting.mcp_enabled = true
  end

  test "a turn token is refused when its user turned AI off" do
    turn = streaming_claude_turn
    @user.update!(ai_enabled: false)

    mcp_post "tools/list", headers: turn_auth(turn)

    assert_response :forbidden
    assert_equal McpController::JSON_RPC_INVALID_REQUEST, rpc_error["code"]
  end

  test "a turn token works with the AI switch on even when no LLM provider is configured" do
    turn = streaming_claude_turn
    @user.update!(ai_enabled: true)
    User.any_instance.stubs(:ai_available?).returns(false)

    mcp_post "tools/list", headers: turn_auth(turn)

    assert_response :success
    assert rpc_result["tools"].any?
  end

  test "a turn token is 401 once its turn completed or failed" do
    turn = streaming_claude_turn
    token = Mcp::TurnToken.generate(turn)

    turn.update!(content: "Done")
    turn.complete!("sess_1")
    mcp_post "tools/list", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :unauthorized

    failed = streaming_claude_turn
    failed_token = Mcp::TurnToken.generate(failed)
    failed.fail!(StandardError.new("x"))
    mcp_post "tools/list", headers: { "Authorization" => "Bearer #{failed_token}" }
    assert_response :unauthorized
  end

  test "an expired turn token is 401" do
    turn = streaming_claude_turn
    token = Mcp::TurnToken.generate(turn)

    travel Mcp::TurnToken::EXPIRES_IN + 1.minute do
      turn.touch
      mcp_post "tools/list", headers: { "Authorization" => "Bearer #{token}" }
    end

    assert_response :unauthorized
  end

  test "a tampered turn token is 401" do
    token = Mcp::TurnToken.generate(streaming_claude_turn)
    data, digest = token.split("--")

    [ "#{data}x--#{digest}", "#{data}--#{digest.reverse}", "#{data}--" ].each do |tampered|
      mcp_post "tools/list", headers: { "Authorization" => "Bearer #{tampered}" }
      assert_response :unauthorized
    end
  end

  test "a turn token naming another user's message is 401" do
    turn = streaming_claude_turn
    other = users(:family_member)
    forged = Rails.application.message_verifier(:mcp_turn).generate(
      { "user_id" => other.id, "assistant_message_id" => turn.id, "scope" => "full" },
      expires_in: 15.minutes, purpose: :mcp_turn
    )

    mcp_post "tools/list", headers: { "Authorization" => "Bearer #{forged}" }

    assert_response :unauthorized
  end

  test "a turn token tool call is audited as claude_chat with the chat and message ids" do
    turn = streaming_claude_turn

    assert_difference -> { AiToolAudit.count }, 1 do
      mcp_post "tools/call", params: { name: "get_accounts", arguments: {} }, headers: turn_auth(turn)
    end

    assert_response :success
    audit = AiToolAudit.order(:created_at).last
    assert_equal "claude_chat", audit.source
    assert_equal turn.chat_id, audit.chat_id
    assert_equal turn.id, audit.assistant_message_id
    assert_equal @user, audit.user
    assert_equal "ok", audit.status
  end

  test "a turn token can call a write tool and the audit names the record" do
    turn = streaming_claude_turn
    transaction = transactions(:one)

    mcp_post "tools/call", params: { name: "update_transaction", arguments: { id: transaction.id, notes: "Set by Claude" } },
      headers: turn_auth(turn)

    assert_response :success
    assert_equal false, rpc_result["isError"]
    assert_equal "Set by Claude", transaction.reload.entry.notes
    audit = AiToolAudit.order(:created_at).last
    assert_equal "claude_chat", audit.source
    assert_equal [ transaction.id ], audit.result_record_ids
  end

  # --- w3-reports exclude-from-reports ------------------------------------------------------------------------

  test "tools/call get_balance_sheet leaves out an account excluded from reports" do
    accounts(:depository).update!(exclude_from_reports: true)

    with_mcp_env do
      mcp_post "tools/call", params: { name: "get_balance_sheet", arguments: { period: "last_30_days" } }

      assert_response :success
      result = rpc_result
      assert_equal false, result["isError"]
      assert_equal BalanceSheet.new(@user.family).net_worth_money.format, result.dig("structuredContent", "net_worth", "current")
    end
  end

  # --- create_goal (w3-reports goal-ai-hooks) ---

  test "tools/list serves create_goal as a write tool that is not destructive" do
    with_mcp_env do
      mcp_post "tools/list"

      tool = rpc_result["tools"].find { |entry| entry["name"] == "create_goal" }
      assert tool, "create_goal is missing from tools/list"
      assert_equal false, tool.dig("annotations", "readOnlyHint")
      assert_equal false, tool.dig("annotations", "destructiveHint")
      assert_includes tool.dig("inputSchema", "required"), "account_ids"
    end
  end

  private
    def with_mcp_env(&block)
      with_env_overrides(MCP_API_TOKEN: TOKEN, MCP_USER_EMAIL: @user.email, &block)
    end

    def streaming_claude_turn
      chat = Chat.create!(user: @user, title: "Claude")
      UserMessage.create!(chat: chat, content: "Hi", ai_model: "sonnet")
      AssistantMessage.create!(chat: chat, ai_model: "sonnet", status: "streaming")
    end

    def turn_auth(turn)
      { "Authorization" => "Bearer #{Mcp::TurnToken.generate(turn)}" }
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
