require "test_helper"

class AssistantTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Replays scripted provider responses and records every request, like Provider::Openai#chat_response
  class ScriptedLlm
    attr_reader :calls

    def initialize(*steps)
      @steps = steps
      @calls = []
    end

    def chat_response(prompt, **options)
      @calls << options.merge(prompt: prompt)
      step = @steps.shift || raise("unexpected chat_response call ##{@calls.size}")

      Array(step[:chunks]).each { |chunk| options[:streamer]&.call(chunk) }
      step[:response]
    end
  end

  setup do
    @chat = chats(:two)
    @chat.update!(latest_assistant_response_id: "resp_previous")
    @prompt = @chat.messages.create!(
      type: "UserMessage",
      content: "What is my net worth?",
      ai_model: "gpt-4.1"
    )
    @turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    @assistant = Assistant.for_chat(@chat)
    Chat.any_instance.stubs(:assistant).returns(@assistant)
    @expected_session_id = @chat.id.to_s
    @expected_user_identifier = ::Digest::SHA256.hexdigest(@chat.user_id.to_s)
  end

  test "errors fail the turn" do
    error = StandardError.new("test error")
    use_llm(step(response: provider_error_response(error)))

    @turn.generate_response

    assert @turn.reload.failed?
    assert_includes @chat.reload.error, "test error"
    assert_equal "resp_previous", @chat.latest_assistant_response_id
  end

  test "handles missing provider gracefully with helpful error message" do
    @assistant.expects(:get_model_provider).with("gpt-4.1").returns(nil)

    mock_registry = mock("registry")
    mock_registry.stubs(:providers).returns([])
    @assistant.stubs(:registry).returns(mock_registry)

    @turn.generate_response

    assert @turn.reload.failed?
    assert_includes @chat.reload.error, "No LLM provider configured that supports model 'gpt-4.1'"
    assert_includes @chat.error, "Please configure an LLM provider (e.g., OpenAI) in settings."
  end

  test "shows available providers in error message when model not supported" do
    @turn.update!(ai_model: "llama-3")
    @assistant.expects(:get_model_provider).with("llama-3").returns(nil)

    mock_provider = mock("openai_provider")
    mock_provider.stubs(:provider_name).returns("OpenAI")
    mock_provider.stubs(:supported_models_description).returns("models starting with: gpt-4, gpt-5, o1, o3")

    mock_registry = mock("registry")
    mock_registry.stubs(:providers).returns([ mock_provider ])
    @assistant.stubs(:registry).returns(mock_registry)

    @turn.generate_response

    error = JSON.parse(@chat.reload.error)
    assert_includes error, "No LLM provider configured that supports model 'llama-3'"
    assert_includes error, "Available providers:"
    assert_includes error, "OpenAI: models starting with: gpt-4, gpt-5, o1, o3"
    assert_includes error, "Use a supported model from the list above"
  end

  test "responds to basic prompt" do
    text_chunks = [
      provider_text_chunk("I do not "),
      provider_text_chunk("have the information "),
      provider_text_chunk("to answer that question")
    ]
    response = provider_response(id: "1", text: text_chunks.map(&:data).join)
    llm = use_llm(step(chunks: [ *text_chunks, provider_response_chunk(response) ], response: provider_success_response(response)))

    assert_no_difference "AssistantMessage.count" do
      @turn.generate_response
    end

    @turn.reload
    assert @turn.complete?
    assert_equal "I do not have the information to answer that question", @turn.content
    assert_equal 0, @turn.tool_calls.size
    assert_equal "1", @chat.reload.latest_assistant_response_id

    assert_equal 1, llm.calls.size
    assert_equal "What is my net worth?", llm.calls.first[:prompt]
    assert_equal "resp_previous", llm.calls.first[:previous_response_id]
    assert_equal @expected_session_id, llm.calls.first[:session_id]
    assert_equal @expected_user_identifier, llm.calls.first[:user_identifier]
  end

  test "responds with tool function calls" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns("test value").once

    call1 = provider_response(id: "1", function_requests: [ function_request("1") ])
    call2 = provider_response(id: "2", text: "Your net worth is $124,200")

    llm = use_llm(
      step(chunks: [ provider_response_chunk(call1) ], response: provider_success_response(call1)),
      step(
        chunks: [ provider_text_chunk("Your net worth is "), provider_text_chunk("$124,200"), provider_response_chunk(call2) ],
        response: provider_success_response(call2)
      )
    )

    @turn.generate_response

    @turn.reload
    assert @turn.complete?
    assert_equal "Your net worth is $124,200", @turn.content
    assert_equal 1, @turn.tool_calls.size
    assert_equal "2", @chat.reload.latest_assistant_response_id

    assert_equal [ "resp_previous", "1" ], llm.calls.map { |call| call[:previous_response_id] }
    assert_equal [ "1" ], llm.calls.last[:function_results].map { |result| result[:call_id] }
  end

  test "runs chained function calls until the model answers" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns("accounts")

    call1 = provider_response(id: "1", function_requests: [ function_request("a") ])
    call2 = provider_response(id: "2", function_requests: [ function_request("b") ])
    call3 = provider_response(id: "3", text: "Done")

    llm = use_llm(
      step(response: provider_success_response(call1)),
      step(response: provider_success_response(call2)),
      step(chunks: [ provider_text_chunk("Done") ], response: provider_success_response(call3))
    )

    @turn.generate_response

    @turn.reload
    assert @turn.complete?
    assert_equal 2, @turn.tool_calls.size
    assert_equal "3", @chat.reload.latest_assistant_response_id
    assert_equal [ "resp_previous", "1", "2" ], llm.calls.map { |call| call[:previous_response_id] }
  end

  test "too many function rounds fail the turn and keep the pointer" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns("accounts")

    steps = (1..(Assistant::Responder::MAX_FUNCTION_ROUNDS + 1)).map do |i|
      step(response: provider_success_response(provider_response(id: i.to_s, function_requests: [ function_request(i.to_s) ])))
    end
    llm = use_llm(*steps)

    @turn.generate_response

    assert @turn.reload.failed?
    assert_equal Assistant::Responder::MAX_FUNCTION_ROUNDS, @turn.tool_calls.size
    assert_equal Assistant::Responder::MAX_FUNCTION_ROUNDS + 1, llm.calls.size
    assert_equal :none, llm.calls.last[:tool_choice], "the last round asks for a text answer"
    assert_equal "resp_previous", @chat.reload.latest_assistant_response_id
  end

  test "a failure after the tool call keeps the partial text, the tool calls and the old pointer" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns("accounts")

    call1 = provider_response(id: "1", function_requests: [ function_request("1") ])
    use_llm(
      step(response: provider_success_response(call1)),
      step(chunks: [ provider_text_chunk("Your net") ], response: provider_error_response(StandardError.new("stream dropped")))
    )

    @turn.generate_response

    @turn.reload
    assert @turn.failed?
    assert_equal "Your net", @turn.content
    assert_equal 1, @turn.tool_calls.size
    assert_equal "resp_previous", @chat.reload.latest_assistant_response_id
  end

  test "a turn that ends with no text fails and can be retried" do
    response = provider_response(id: "1")
    use_llm(step(response: provider_success_response(response)))

    @turn.generate_response

    assert @turn.reload.failed?
    assert @turn.retryable?
    assert_includes @chat.reload.error, "no text"
    assert_equal "resp_previous", @chat.latest_assistant_response_id
  end

  test "the static prompt prefix is byte-identical across chats and families" do
    first = Assistant.config_for(chats(:one))[:instructions]
    second = Assistant.config_for(chats(:two))[:instructions]

    assert first.start_with?(Assistant::Configurable::STATIC_INSTRUCTIONS)
    assert second.start_with?(Assistant::Configurable::STATIC_INSTRUCTIONS)
    assert Assistant::Configurable::STATIC_INSTRUCTIONS.frozen?
    assert_not_includes Assistant::Configurable::STATIC_INSTRUCTIONS, Date.current.iso8601
  end

  test "the session context shows today's date in the family's time zone" do
    family = chats(:one).user.family
    family.update!(timezone: "Europe/Kyiv", currency: "UAH")

    # 23:30 UTC on Nov 14 is already Nov 15 in Kyiv
    travel_to Time.utc(2026, 11, 14, 23, 30) do
      instructions = Assistant.config_for(chats(:one).reload)[:instructions]
      context = instructions.delete_prefix(Assistant::Configurable::STATIC_INSTRUCTIONS)

      assert_includes context, "Today's date: 2026-11-15 (time zone Europe/Kyiv)"
      assert_includes context, "Preferred currency: UAH"
    end
  end

  test "the session context lists accounts and categories up to their caps" do
    family = chats(:one).user.family
    context = Assistant.config_for(chats(:one))[:instructions].delete_prefix(Assistant::Configurable::STATIC_INSTRUCTIONS)

    family.accounts.visible.each { |account| assert_includes context, "- #{account.name}:" } if family.accounts.visible.count <= Assistant::Configurable::ACCOUNTS_ROSTER_LIMIT
    family.categories.each { |category| assert_includes context, category.name } if family.categories.count <= Assistant::Configurable::CATEGORY_NAMES_LIMIT
    assert_includes context, "Months: budgets and monthly totals use calendar months."
  end

  test "the session context describes fiscal months when they are on" do
    family = chats(:one).user.family
    family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    context = Assistant.config_for(chats(:one).reload)[:instructions].delete_prefix(Assistant::Configurable::STATIC_INSTRUCTIONS)

    assert_includes context, "fiscal months that start on day 25"
  end

  test "a failing tool still gives a completed turn and sends the error to the model" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).raises(RuntimeError, "boom with internals")

    call1 = provider_response(id: "1", function_requests: [ function_request("1") ])
    call2 = provider_response(id: "2", text: "I could not load your accounts")

    llm = use_llm(
      step(response: provider_success_response(call1)),
      step(chunks: [ provider_text_chunk("I could not load your accounts") ], response: provider_success_response(call2))
    )

    @turn.generate_response

    @turn.reload
    assert @turn.complete?
    assert_equal 1, @turn.tool_calls.size
    assert_equal "2", @chat.reload.latest_assistant_response_id

    output = llm.calls.last[:function_results].first[:output]
    # function_result is jsonb, so the stored result has string keys
    assert_equal "get_accounts failed unexpectedly", output["error"]
    refute_match "internals", output.to_json
  end

  # --- Engine dispatch -----------------------------------------------------------------------------------

  test "a Claude model goes to the Claude adapter, not the OpenAI path" do
    @turn.update!(ai_model: "sonnet")
    Assistant::Claude.any_instance.expects(:respond_to).with(@turn)
    @assistant.expects(:get_model_provider).never

    @assistant.respond_to(@turn)
  end

  test "a Claude model id goes to the Claude adapter with the chat's instructions" do
    @turn.update!(ai_model: "claude-opus-5-5")
    claude = mock("claude")
    claude.expects(:respond_to).with(@turn)
    Assistant::Claude.expects(:new).with(@chat, instructions: @assistant.instructions).returns(claude)

    @assistant.respond_to(@turn)
  end

  test "a GPT model goes to the built-in path" do
    Assistant::Claude.expects(:new).never
    response = provider_response(id: "1", text: "Hi")
    use_llm(step(response: provider_success_response(response)))
    @turn.start!

    @assistant.respond_to(@turn)

    assert @turn.reload.complete?
    assert_equal "1", @chat.reload.latest_assistant_response_id
  end

  # --- Tool registry --------------------------------------------------------------------------------------
  # The chat gets every tool, writes and deletes included, with no approval prompt (owner answer 2). No test may
  # assert that the chat lacks write, delete, rule or transfer tools.

  test "the chat gets the full tool set in the registry order" do
    assert_equal Assistant.function_classes_for(:full), Assistant.config_for(@chat)[:functions]
    assert_equal Assistant.function_classes, Assistant.function_classes_for(:full)
  end

  test "the read scope keeps only read tools, in the registry order" do
    read = Assistant.function_classes_for(:read)

    assert read.any?
    assert read.all?(&:read_only?)
    assert_equal Assistant.function_classes.select(&:read_only?), read
    assert_not_includes read, Assistant::Function::ImportBankStatement
  end

  test "the chat gets the write, delete and balance tools" do
    names = Assistant.config_for(@chat)[:functions].map(&:name)

    %w[create_transaction update_transaction delete_transaction create_category update_category create_tag update_tag
       set_opening_balance record_balance get_uncategorized_transactions].each { |name| assert_includes names, name }
  end

  test "an unknown tool scope is refused" do
    assert_raises(ArgumentError) { Assistant.function_classes_for(:admin) }
  end

  # --- Tool-call audit ------------------------------------------------------------------------------------

  test "each chat tool call is audited as the built-in chat with the turn's message" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns({ accounts: [] })

    call1 = provider_response(id: "1", function_requests: [ function_request("1") ])
    call2 = provider_response(id: "2", text: "Done")
    use_llm(step(response: provider_success_response(call1)), step(response: provider_success_response(call2)))

    assert_difference -> { AiToolAudit.count }, 1 do
      @turn.generate_response
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal "builtin_chat", audit.source
    assert_equal "get_accounts", audit.tool_name
    assert_equal @chat.user, audit.user
    assert_equal @chat.id, audit.chat_id
    assert_equal @turn.id, audit.assistant_message_id
    assert_equal "ok", audit.status
  end

  test "a requeue deletes the turn's tool calls but keeps their audit rows" do
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns({ accounts: [] })

    call1 = provider_response(id: "1", function_requests: [ function_request("1") ])
    use_llm(step(response: provider_success_response(call1)), step(response: provider_error_response(StandardError.new("down"))))

    @turn.generate_response
    @turn.reload
    assert @turn.failed?
    assert_equal 1, @turn.tool_calls.size

    @turn.requeue!

    assert_equal 0, @turn.reload.tool_calls.count
    assert_equal 1, AiToolAudit.where(assistant_message_id: @turn.id).count
  end

  test "deleting the chat keeps its audit rows" do
    AiToolAudit.create!(family: @chat.user.family, user: @chat.user, source: "builtin_chat", chat_id: @chat.id,
      assistant_message_id: @turn.id, tool_name: "get_accounts", scope_tag: "read", status: "ok")

    @chat.destroy!

    assert_equal 1, AiToolAudit.where(chat_id: @chat.id).count
  end

  # --- create_goal (w3-reports goal-ai-hooks) ---

  test "the built-in chat gets create_goal" do
    assert_includes Assistant.config_for(@chat)[:functions], Assistant::Function::CreateGoal
    assert_includes Assistant.function_classes, Assistant::Function::CreateGoal
  end

  private
    def use_llm(*steps)
      ScriptedLlm.new(*steps).tap do |llm|
        @assistant.stubs(:get_model_provider).with("gpt-4.1").returns(llm)
      end
    end

    def step(response:, chunks: [])
      { response: response, chunks: chunks }
    end

    def function_request(call_id)
      Provider::LlmConcept::ChatFunctionRequest.new(
        id: "fc_#{call_id}",
        call_id: call_id,
        function_name: "get_accounts",
        function_args: "{}"
      )
    end

    def provider_response(id:, text: nil, function_requests: [])
      Provider::LlmConcept::ChatResponse.new(
        id: id,
        model: "gpt-4.1",
        messages: text ? [ Provider::LlmConcept::ChatMessage.new(id: id, output_text: text) ] : [],
        function_requests: function_requests
      )
    end

    def provider_text_chunk(text)
      Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text, usage: nil)
    end

    def provider_response_chunk(response)
      Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: response, usage: nil)
    end
end
