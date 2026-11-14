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

  private
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
