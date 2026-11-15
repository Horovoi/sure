require "test_helper"

# Usage accounting across a function-call round trip, with the real OpenAI provider and a stubbed HTTP client
class Assistant::ResponderTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
    @family = @chat.user.family
    @message = UserMessage.create!(chat: @chat, content: "What are my accounts?", ai_model: "gpt-4.1")

    function = Assistant::Function::GetAccounts.new(@chat.user)
    function.stubs(:call).returns({ "accounts" => [] })
    @function_tool_caller = Assistant::FunctionToolCaller.new([ function ])
  end

  test "native provider records the first call's usage when the follow-up fails" do
    provider = Provider::Openai.new("test-token")

    first = {
      "id" => "resp_1", "model" => "gpt-4.1",
      "output" => [ { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "get_accounts", "arguments" => "{}" } ],
      "usage" => { "input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120 }
    }
    provider.send(:client).stubs(:responses).returns(streaming_responses(first))

    assert_raises(Provider::Openai::Error) { responder(provider).respond }

    usages = @family.llm_usages.order(:created_at).to_a
    assert_equal 2, usages.size
    assert_equal 120, usages.first.total_tokens
    assert_nil usages.first.metadata["error"]
    assert_equal 0, usages.last.total_tokens
    assert_includes usages.last.metadata["error"], "connection reset"
  end

  test "generic provider records one row per call when the follow-up fails" do
    provider = Provider::Openai.new("test-token", uri_base: "http://llm.local/v1", model: "local-model")
    client = provider.send(:client)

    first = {
      "id" => "chatcmpl_1", "model" => "local-model",
      "choices" => [ { "message" => { "role" => "assistant", "content" => nil,
        "tool_calls" => [ { "id" => "call_1", "type" => "function", "function" => { "name" => "get_accounts", "arguments" => "{}" } } ] } } ],
      "usage" => { "prompt_tokens" => 50, "completion_tokens" => 10, "total_tokens" => 60 }
    }

    client.expects(:chat).twice.returns(first).then.raises(Faraday::ConnectionFailed.new("connection reset"))

    assert_raises(Provider::Openai::Error) { responder(provider, model: "local-model").respond }

    usages = @family.llm_usages.order(:created_at).to_a
    assert_equal 2, usages.size, "the follow-up failure must not add a second row for the first call"
    assert_equal 60, usages.first.total_tokens
    assert_nil usages.first.metadata["error"]
    assert_includes usages.last.metadata["error"], "connection reset"
  end

  test "the last permitted round asks for a text answer and the turn completes" do
    rounds = Assistant::Responder::MAX_FUNCTION_ROUNDS
    steps = (1..rounds).map { |i| scripted_response(id: "r#{i}", function_call: "call_#{i}") }
    steps << scripted_response(id: "final", chunks: [ "Here is what I found" ])
    llm = ScriptedLlm.new(steps)

    response = Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: llm).respond

    assert_equal "final", response.id
    assert_equal rounds + 1, llm.calls.size
    assert_equal [ nil ] * rounds + [ :none ], llm.calls.map { |call| call[:tool_choice] }
    assert llm.calls.last[:functions].any?, "the tool definitions stay in the final request"
  end

  test "a model that still asks for functions after the last round raises" do
    rounds = Assistant::Responder::MAX_FUNCTION_ROUNDS
    steps = (1..(rounds + 1)).map { |i| scripted_response(id: "r#{i}", function_call: "call_#{i}") }
    llm = ScriptedLlm.new(steps)

    assert_raises(Assistant::Responder::TooManyFunctionRoundsError) do
      Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: llm).respond
    end
    assert_equal rounds + 1, llm.calls.size
  end

  test "ASSISTANT_MAX_FUNCTION_ROUNDS overrides the round limit" do
    with_env_overrides("ASSISTANT_MAX_FUNCTION_ROUNDS" => "2") do
      assert_equal 2, Assistant::Responder.max_function_rounds
    end

    with_env_overrides("ASSISTANT_MAX_FUNCTION_ROUNDS" => "nonsense") do
      assert_equal Assistant::Responder::MAX_FUNCTION_ROUNDS, Assistant::Responder.max_function_rounds
    end
  end

  test "a turn with no text raises EmptyResponseError" do
    llm = ScriptedLlm.new([ scripted_response(id: "r1", function_call: "call_1"), scripted_response(id: "r2", chunks: [ "  " ]) ])

    assert_raises(Assistant::Responder::EmptyResponseError) do
      Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: llm).respond
    end
  end

  test "leading whitespace chunks are held and merged into the first text chunk" do
    llm = ScriptedLlm.new([ scripted_response(id: "r1", chunks: [ " ", " ", "5", " UAH" ]) ])
    emitted = []

    responder = Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: llm)
    responder.on(:output_text) { |text| emitted << text }
    responder.respond

    assert_equal [ "  5", " UAH" ], emitted
  end

  test "text a provider returns without streaming still reaches the turn" do
    llm = ScriptedLlm.new([ scripted_response(id: "r1", text: "Unstreamed answer") ])
    emitted = []

    responder = Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: llm)
    responder.on(:output_text) { |text| emitted << text }
    responder.respond

    assert_equal [ "Unstreamed answer" ], emitted
  end

  private
    # Replays scripted responses like Provider::Openai#chat_response, streaming their chunks, and records each call
    class ScriptedLlm
      attr_reader :calls

      def initialize(steps)
        @steps = steps
        @calls = []
      end

      def chat_response(prompt, **options)
        @calls << options
        step = @steps.shift || raise("unexpected chat_response call ##{@calls.size}")
        step[:chunks].each { |text| options[:streamer]&.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text, usage: nil)) }
        Provider::Response.new(success?: true, data: step[:response], error: nil)
      end
    end

    def scripted_response(id:, chunks: [], text: nil, function_call: nil)
      text ||= chunks.join.presence
      response = Provider::LlmConcept::ChatResponse.new(
        id: id,
        model: "gpt-4.1",
        messages: text ? [ Provider::LlmConcept::ChatMessage.new(id: id, output_text: text) ] : [],
        function_requests: function_call ? [ Provider::LlmConcept::ChatFunctionRequest.new(id: "fc_#{function_call}", call_id: function_call, function_name: "get_accounts", function_args: "{}") ] : []
      )
      { response: response, chunks: chunks }
    end

    def responder(provider, model: "gpt-4.1")
      @message.update!(ai_model: model)
      Assistant::Responder.new(message: @message, instructions: nil, function_tool_caller: @function_tool_caller, llm: provider)
    end

    # Like client.responses: the first request streams a completed response asking for a function, the second fails
    def streaming_responses(first)
      calls = 0
      Object.new.tap do |responses|
        responses.define_singleton_method(:create) do |parameters:|
          calls += 1
          raise Faraday::ConnectionFailed.new("connection reset") if calls > 1

          parameters[:stream].call({ "type" => "response.completed", "response" => first })
          nil
        end
      end
    end
end
