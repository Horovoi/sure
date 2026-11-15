require "test_helper"

# The Claude chat adapter against a stubbed bridge (WebMock, NDJSON bodies as claude_bridge/server.ts sends them)
class Assistant::ClaudeTest < ActiveSupport::TestCase
  BRIDGE_URL = "http://claude-bridge.test:3339".freeze
  BRIDGE_TOKEN = ("b" * 40).freeze
  TURN_URL = "#{BRIDGE_URL}/turn".freeze

  setup do
    @user = users(:family_admin)
    @user.family.update!(timezone: "Europe/Kyiv")
    @chat = Chat.create!(user: @user, title: "Claude chat", latest_assistant_response_id: "resp_openai")
    @prompt = UserMessage.create!(chat: @chat, content: "What did I spend on food?", ai_model: "sonnet")
    @turn = AssistantMessage.create!(chat: @chat, ai_model: "sonnet")
  end

  # --- Model routing --------------------------------------------------------------------------------------

  test "Claude ids and aliases are Claude models; OpenAI ids are not" do
    %w[sonnet opus haiku claude-sonnet-5-5 claude-opus-5-5 sonnet[1m] Opus].each do |model|
      assert Assistant::Claude.handles?(model), model
    end

    [ "gpt-4.1", "gpt-5", "o3", "", nil ].each do |model|
      assert_not Assistant::Claude.handles?(model), model.inspect
    end
  end

  test "configured needs both bridge variables" do
    with_env_overrides(CLAUDE_BRIDGE_URL: BRIDGE_URL, CLAUDE_BRIDGE_TOKEN: nil) { assert_not Assistant::Claude.configured? }
    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: BRIDGE_TOKEN) { assert_not Assistant::Claude.configured? }
    with_bridge { assert Assistant::Claude.configured? }
  end

  # --- A turn ---------------------------------------------------------------------------------------------

  test "text and result complete the turn, keep the OpenAI pointer and record subscription usage" do
    stub_turn(
      { type: "session", session_id: "sess_new", model: "claude-sonnet-5-5" },
      { type: "text", delta: "You spent " },
      { type: "text", delta: "₴1,200 on food." },
      result_event(session_id: "sess_new")
    )

    assert_difference -> { LlmUsage.count }, 1 do
      with_bridge { @turn.generate_response }
    end

    @turn.reload
    assert @turn.complete?
    assert_equal "You spent ₴1,200 on food.", @turn.content
    assert_equal "sess_new", @turn.provider_id
    assert_equal "resp_openai", @chat.reload.latest_assistant_response_id
    assert_nil @chat.error

    usage = LlmUsage.order(:created_at).last
    assert_equal LlmUsage::SUBSCRIPTION_PROVIDER, usage.provider
    assert_equal "claude-sonnet-5-5", usage.model
    assert_equal "chat", usage.operation
    assert_equal 1000 + 300 + 5000, usage.prompt_tokens
    assert_equal 200, usage.completion_tokens
    assert_equal 1000 + 300 + 5000 + 200, usage.total_tokens
    expected_cost = LlmUsage.calculate_cost(model: "claude-sonnet-5-5", prompt_tokens: 1000, completion_tokens: 200,
      cache_creation_tokens: 300, cache_read_tokens: 5000)
    assert expected_cost.positive?
    assert_in_delta expected_cost, usage.estimated_cost.to_f, 0.000001
    assert_equal "subscription", usage.metadata["billing"]
    assert_equal "sess_new", usage.metadata["session_id"]
    assert_equal @turn.id, usage.metadata["assistant_message_id"]
    assert_equal 3, usage.metadata["num_turns"]
  end

  test "the request carries the model, prompt, system prompt, limits and a live turn token" do
    request_body = nil
    stub_request(:post, TURN_URL)
      .with(headers: { "Authorization" => "Bearer #{BRIDGE_TOKEN}" }) { |request| request_body = JSON.parse(request.body) }
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Hi" }, result_event))

    with_bridge { @turn.generate_response }

    assert @turn.reload.complete?
    assert_equal "sonnet", request_body["model"]
    assert_equal @turn.id, request_body["turn_id"]
    assert_equal "What did I spend on food?", request_body["prompt"]
    assert_nil request_body["resume_session_id"]
    assert_includes request_body["system_prompt"], "## Session context"
    assert_includes request_body["system_prompt"], "mcp__sure__"
    assert_equal Assistant::Claude::MAX_TOOL_ROUNDS, request_body.dig("limits", "max_turns")
    assert_equal "http://localhost:3000/mcp", request_body.dig("mcp", "url")

    # The token named this turn; it stops working once the turn completed
    token = request_body.dig("mcp", "token")
    assert_nil Mcp::TurnToken.credential_for(token)
    @turn.update_column(:status, "streaming")
    credential = Mcp::TurnToken.credential_for(token)
    assert credential.turn?
    assert_equal :full, credential.scope
    assert_equal @turn, credential.assistant_message
  end

  test "CLAUDE_BRIDGE_MCP_URL overrides the MCP URL sent to the bridge" do
    request_body = nil
    stub_request(:post, TURN_URL).with { |request| request_body = JSON.parse(request.body) }
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Hi" }, result_event))

    with_bridge(CLAUDE_BRIDGE_MCP_URL: "http://127.0.0.1:3333/mcp") { @turn.generate_response }

    assert_equal "http://127.0.0.1:3333/mcp", request_body.dig("mcp", "url")
  end

  test "a tool event saves the call without the mcp prefix and its result fills in" do
    stub_turn(
      { type: "tool", id: "toolu_1", name: "mcp__sure__get_transactions", input: { "search" => "food" } },
      { type: "tool_result", id: "toolu_1", is_error: false, content: { transactions: [], total_results: 0 }.to_json },
      { type: "tool", id: "toolu_2", name: "mcp__sure__delete_transaction", input: { "id" => "x" } },
      { type: "tool_result", id: "toolu_2", is_error: true, content: "No such record" },
      { type: "text", delta: "Nothing found." },
      result_event
    )

    with_bridge { @turn.generate_response }

    assert @turn.reload.complete?
    calls = @turn.tool_calls.order(:created_at).to_a
    assert_equal 2, calls.size
    assert(calls.all? { |call| call.is_a?(ToolCall::Function) })

    first, second = calls
    assert_equal "get_transactions", first.function_name
    assert_equal "toolu_1", first.provider_id
    assert_equal({ "search" => "food" }, first.function_arguments)
    assert_equal 0, first.function_result["total_results"]

    assert_equal "delete_transaction", second.function_name
    assert_equal "No such record", second.function_result["text"]
    assert_equal true, second.function_result["is_error"]
  end

  test "a heartbeat moves updated_at without changing the message" do
    @turn.start!
    @turn.update_column(:updated_at, 9.minutes.ago)
    stub_turn({ type: "heartbeat" }, { type: "error", code: "timeout", message: "x", retryable: true })

    assert_raises(Assistant::Claude::Error) { with_bridge { Assistant::Claude.new(@chat).respond_to(@turn) } }

    @turn.reload
    assert @turn.updated_at > 1.minute.ago
    assert_not_includes AssistantMessage.stale, @turn
    assert_equal "", @turn.content
  end

  test "leading whitespace is dropped so a whitespace-only answer cannot complete" do
    stub_turn({ type: "text", delta: "\n  " }, { type: "text", delta: "Answer" }, result_event)

    with_bridge { @turn.generate_response }

    assert_equal "Answer", @turn.reload.content
  end

  test "a result with no text fails the turn and it can be retried" do
    stub_turn({ type: "text", delta: "   " }, result_event)

    with_bridge { @turn.generate_response }

    assert @turn.reload.failed?
    assert_includes @chat.reload.error, I18n.t("assistant.claude.errors.empty")
    assert_equal I18n.t("assistant.claude.errors.empty"), @chat.user_facing_error
    assert @turn.retryable?
    assert_equal "resp_openai", @chat.latest_assistant_response_id
  end

  test "a stream that ends without a result fails the turn as incomplete" do
    stub_turn({ type: "text", delta: "Partial" })

    with_bridge { @turn.generate_response }

    assert @turn.reload.failed?
    assert_equal "Partial", @turn.content
    assert_equal I18n.t("assistant.claude.errors.incomplete"), @chat.reload.user_facing_error
  end

  # --- Errors ---------------------------------------------------------------------------------------------

  test "every bridge error code raises an actionable error" do
    Assistant::Claude::Error::BRIDGE_CODES.each do |code|
      next if code == "session_not_found" # retried fresh only when resuming; covered below

      stub_turn({ type: "error", code: code, message: "Detail from the bridge", retryable: false })
      turn = AssistantMessage.create!(chat: @chat, ai_model: "sonnet", status: "streaming")

      error = assert_raises(Assistant::Claude::Error, code) { with_bridge { Assistant::Claude.new(@chat).respond_to(turn) } }
      assert_equal code, error.code
      assert error.message.present?, code
      assert_no_match(/translation missing/i, error.message, code)

      turn.update_column(:status, "failed")
      WebMock.reset!
    end
  end

  test "a used-up usage window names its reset time in Kyiv" do
    # 12:20 UTC is 14:20 in Kyiv in November
    travel_to Time.utc(2026, 11, 15, 10, 0) do
      stub_turn({ type: "error", code: "usage_limit", message: "Claude usage limit reached", reset_at: "2026-11-15T12:20:00.000Z", retryable: false })

      with_bridge { @turn.generate_response }

      message = @chat.reload.user_facing_error
      assert_includes message, "14:20"
      assert_includes message, "Europe/Kyiv"
    end
  end

  test "an unknown error code reads as internal" do
    stub_turn({ type: "error", code: "something_new", message: "odd", retryable: false })

    with_bridge { @turn.generate_response }

    assert_match I18n.t("assistant.claude.errors.internal"), @chat.reload.user_facing_error
  end

  test "a refused connection is retried once and then names the bridge command" do
    stub_request(:post, TURN_URL).to_raise(Errno::ECONNREFUSED)

    with_bridge { @turn.generate_response }

    assert_requested :post, TURN_URL, times: 2
    assert @turn.reload.failed?
    assert_includes @chat.reload.user_facing_error, "bin/claude-bridge status"
  end

  test "a refused first attempt then a working one completes the turn" do
    stub_request(:post, TURN_URL)
      .to_raise(Errno::ECONNREFUSED).then
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Hi" }, result_event))

    with_bridge { @turn.generate_response }

    assert @turn.reload.complete?
  end

  test "a read timeout is a timeout and is not retried" do
    stub_request(:post, TURN_URL).to_raise(Net::ReadTimeout)

    with_bridge { @turn.generate_response }

    assert_requested :post, TURN_URL, times: 1
    assert_equal I18n.t("assistant.claude.errors.timeout"), @chat.reload.user_facing_error
  end

  test "a wrong bridge token says how to fix it" do
    stub_request(:post, TURN_URL).to_return(status: 401, body: ndjson({ type: "error", code: "unauthorized", message: "Missing or wrong bridge token.", retryable: false }))

    with_bridge { @turn.generate_response }

    assert_equal I18n.t("assistant.claude.errors.unauthorized"), @chat.reload.user_facing_error
  end

  test "a busy bridge (429) asks to retry later" do
    stub_request(:post, TURN_URL).to_return(status: 429, body: ndjson({ type: "error", code: "busy", message: "Claude is already answering 2 messages.", retryable: true }))

    with_bridge { @turn.generate_response }

    assert_equal I18n.t("assistant.claude.errors.busy"), @chat.reload.user_facing_error
  end

  test "a line that is not JSON is a bad response" do
    stub_request(:post, TURN_URL).to_return(status: 200, body: "{not json\n")

    with_bridge { @turn.generate_response }

    assert @turn.reload.failed?
    assert_includes @chat.reload.user_facing_error, I18n.t("assistant.claude.errors.bad_response")
  end

  test "without the bridge variables the turn fails with the install command" do
    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil) { @turn.generate_response }

    assert @turn.reload.failed?
    assert_includes @chat.reload.user_facing_error, "bin/claude-bridge install"
  end

  # --- Continuity -----------------------------------------------------------------------------------------

  test "a turn after a completed Claude turn resumes its session and sends only the new prompt" do
    earlier_claude_turn(provider_id: "sess_previous")
    request_body = capture_turn_body

    with_bridge { @turn.generate_response }

    assert @turn.reload.complete?
    assert_equal "sess_previous", request_body.call["resume_session_id"]
    assert_equal "What did I spend on food?", request_body.call["prompt"]
  end

  test "a turn after an OpenAI turn starts fresh with the earlier messages as a transcript" do
    earlier_turn(ai_model: "gpt-4.1", provider_id: "resp_openai", question: "How much is in savings?", answer: "₴50,000.")
    request_body = capture_turn_body

    with_bridge { @turn.generate_response }

    body = request_body.call
    assert_nil body["resume_session_id"]
    assert_includes body["prompt"], "<earlier_conversation>"
    assert_includes body["prompt"], "User: How much is in savings?"
    assert_includes body["prompt"], "Assistant: ₴50,000."
    assert body["prompt"].rstrip.end_with?("What did I spend on food?")
  end

  test "the transcript skips failed turns and keeps the last 20 messages" do
    12.times do |i|
      earlier_turn(ai_model: "gpt-4.1", question: "Question #{i}", answer: "Answer #{i}", at: (30 - i).minutes.ago)
    end
    failed = AssistantMessage.create!(chat: @chat, ai_model: "sonnet", status: "failed", content: "Broken half answer")
    failed.update_columns(created_at: 2.minutes.ago)
    request_body = capture_turn_body

    with_bridge { @turn.generate_response }

    prompt = request_body.call["prompt"]
    assert_not_includes prompt, "Broken half answer"
    assert_not_includes prompt, "Question 1\n"
    assert_includes prompt, "Answer 11"
    assert_equal 20, prompt.scan(/^(User|Assistant): /).size
  end

  test "a session the bridge no longer has is retried once as a fresh session with a transcript" do
    earlier_claude_turn(provider_id: "sess_gone")
    bodies = []
    stub_request(:post, TURN_URL)
      .with { |request| bodies << JSON.parse(request.body) }
      .to_return(status: 200, body: ndjson({ type: "error", code: "session_not_found", message: "not found", retryable: false })).then
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Fresh answer" }, result_event(session_id: "sess_fresh")))

    with_bridge { @turn.generate_response }

    assert @turn.reload.complete?
    assert_equal "sess_fresh", @turn.provider_id
    assert_equal 2, bodies.size
    assert_equal "sess_gone", bodies.first["resume_session_id"]
    assert_nil bodies.last["resume_session_id"]
    assert_includes bodies.last["prompt"], "<earlier_conversation>"
  end

  test "a fresh turn that gets session_not_found is not retried" do
    stub_turn({ type: "error", code: "session_not_found", message: "not found", retryable: false })

    with_bridge { @turn.generate_response }

    assert_requested :post, TURN_URL, times: 1
    assert @turn.reload.failed?
  end

  test "a failed Claude turn is retried by requeue and then completes" do
    stub_request(:post, TURN_URL)
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Half" }, { type: "error", code: "overloaded", message: "x", retryable: true })).then
      .to_return(status: 200, body: ndjson({ type: "text", delta: "Full answer" }, result_event(session_id: "sess_retry")))

    with_bridge do
      @turn.generate_response
      assert @turn.reload.failed?
      assert_equal "Half", @turn.content

      assert_enqueued_with(job: AssistantResponseJob) { @chat.retry_last_turn! }
      @turn.reload.generate_response
    end

    assert @turn.reload.complete?
    assert_equal "Full answer", @turn.content
    assert_equal "sess_retry", @turn.provider_id
  end

  test "a turn the reaper failed meanwhile is not completed" do
    stub_turn({ type: "text", delta: "Late" }, result_event)
    turn_id = @turn.id
    claude = Assistant::Claude.new(@chat)
    # The reaper fails the turn while the bridge is still answering, just before the result is applied
    claude.define_singleton_method(:record_usage) { |_result| AssistantMessage.where(id: turn_id).update_all(status: "failed") }
    Assistant::Claude.stubs(:new).returns(claude)

    with_bridge { assert_nothing_raised { @turn.generate_response } }

    assert @turn.reload.failed?
    assert_nil @turn.provider_id
  end

  # --- Status and models ----------------------------------------------------------------------------------

  test "status returns the bridge health, or a down state that never raises" do
    stub_request(:get, "#{BRIDGE_URL}/health").to_return(status: 200, body: { ok: true, signed_in: true, plan: "max" }.to_json + "\n")
    with_bridge do
      status = Assistant::Claude.status
      assert status["ok"]
      assert status["configured"]
      assert_equal "max", status["plan"]
    end

    stub_request(:get, "#{BRIDGE_URL}/health").to_raise(Errno::ECONNREFUSED)
    with_bridge do
      status = Assistant::Claude.status
      assert_not status["ok"]
      assert_equal "unreachable", status.dig("error", "code")
    end

    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil) do
      assert_equal({ "ok" => false, "configured" => false }, Assistant::Claude.status)
    end
  end

  test "model options come from the bridge, else the aliases, and only Claude models" do
    stub_request(:get, "#{BRIDGE_URL}/models").to_return(status: 200, body: {
      models: [ { value: "opus", display_name: "Opus" }, { value: "default", display_name: "Default" }, { value: "haiku", display_name: "Haiku" } ]
    }.to_json + "\n")
    with_bridge { assert_equal [ [ "Opus", "opus" ], [ "Haiku", "haiku" ] ], Assistant::Claude.model_options }

    Rails.cache.delete(Assistant::Claude::MODELS_CACHE_KEY)
    stub_request(:get, "#{BRIDGE_URL}/models").to_raise(Errno::ECONNREFUSED)
    with_bridge { assert_equal %w[opus sonnet haiku], Assistant::Claude.model_options.map(&:last) }
  ensure
    Rails.cache.delete(Assistant::Claude::MODELS_CACHE_KEY)
  end

  private
    def with_bridge(**extra, &block)
      with_env_overrides(CLAUDE_BRIDGE_URL: BRIDGE_URL, CLAUDE_BRIDGE_TOKEN: BRIDGE_TOKEN, **extra, &block)
    end

    def ndjson(*events)
      events.map(&:to_json).join("\n") + "\n"
    end

    def stub_turn(*events)
      stub_request(:post, TURN_URL).to_return(status: 200, body: ndjson(*events), headers: { "Content-Type" => "application/x-ndjson" })
    end

    # Stubs a plain answer and returns a lambda for the last request body
    def capture_turn_body
      body = nil
      stub_request(:post, TURN_URL).with { |request| body = JSON.parse(request.body) }
        .to_return(status: 200, body: ndjson({ type: "text", delta: "Answer" }, result_event))
      -> { body }
    end

    def result_event(session_id: "sess_1")
      {
        type: "result",
        session_id: session_id,
        model: "claude-sonnet-5-5",
        usage: { input_tokens: 1000, output_tokens: 200, cache_creation_input_tokens: 300, cache_read_input_tokens: 5000 },
        total_cost_usd: 0.5,
        num_turns: 3,
        duration_ms: 4200
      }
    end

    def earlier_claude_turn(provider_id:)
      earlier_turn(ai_model: "sonnet", provider_id: provider_id, question: "Earlier question", answer: "Earlier answer")
    end

    # A completed prompt and answer before the turn under test
    def earlier_turn(ai_model:, question:, answer:, provider_id: nil, at: 10.minutes.ago)
      user_message = UserMessage.create!(chat: @chat, content: question, ai_model: ai_model)
      user_message.update_columns(created_at: at)
      assistant = AssistantMessage.create!(chat: @chat, ai_model: ai_model, status: "complete", content: answer, provider_id: provider_id)
      assistant.update_columns(created_at: at + 1.second)
    end
end
