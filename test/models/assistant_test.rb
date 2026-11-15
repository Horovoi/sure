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
    @turn.update!(ai_model: "claude-3")
    @assistant.expects(:get_model_provider).with("claude-3").returns(nil)

    mock_provider = mock("openai_provider")
    mock_provider.stubs(:provider_name).returns("OpenAI")
    mock_provider.stubs(:supported_models_description).returns("models starting with: gpt-4, gpt-5, o1, o3")

    mock_registry = mock("registry")
    mock_registry.stubs(:providers).returns([ mock_provider ])
    @assistant.stubs(:registry).returns(mock_registry)

    @turn.generate_response

    error = JSON.parse(@chat.reload.error)
    assert_includes error, "No LLM provider configured that supports model 'claude-3'"
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
    assert_equal "get_accounts failed unexpectedly", output[:error]
    refute_match "internals", output.to_json
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

  test "an unknown tool scope is refused" do
    assert_raises(ArgumentError) { Assistant.function_classes_for(:admin) }
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
