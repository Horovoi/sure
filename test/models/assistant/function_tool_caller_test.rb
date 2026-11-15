require "test_helper"

class Assistant::FunctionToolCallerTest < ActiveSupport::TestCase
  class ProbeFunction < Assistant::Function
    class << self
      def name
        "probe"
      end

      def description
        "Raises whatever the test sets"
      end
    end

    attr_accessor :to_raise, :received

    def call(params = {})
      self.received = params
      raise to_raise if to_raise

      { ok: true }
    end
  end

  setup do
    @function = ProbeFunction.new(users(:family_admin))
    @caller = Assistant::FunctionToolCaller.new([ @function ])
  end

  test "runs the function with parsed arguments" do
    result = call_tool(args: '{"page": 2}')

    assert_equal({ ok: true }, result)
    assert_equal({ "page" => 2 }, @function.received)
  end

  test "blank arguments become an empty object" do
    [ "", nil ].each do |args|
      assert_equal({ ok: true }, call_tool(args: args))
      assert_equal({}, @function.received)
    end
  end

  test "unknown tool returns an error with a hint" do
    result = call_tool(name: "drop_tables")

    assert_equal "Unknown tool: drop_tables", result[:error]
    assert_equal "Only call tools from the provided list.", result[:hint]
  end

  test "invalid JSON arguments return an error with a hint" do
    result = call_tool(args: "{not json")

    assert_equal "Arguments were not valid JSON", result[:error]
    assert_match "valid JSON", result[:hint]
    assert_nil @function.received
  end

  test "arguments that are not a JSON object are an argument error" do
    result = call_tool(args: "[1, 2]")

    assert_equal "Arguments must be a JSON object", result[:error]
    assert_match "YYYY-MM-DD", result[:hint]
  end

  test "record not found hides the SQL" do
    @function.to_raise = ActiveRecord::RecordNotFound.new(%(Couldn't find Account with 'id'="x" [WHERE "accounts"."family_id" = $1]))

    result = call_tool

    assert_equal "No such record, or it is not one you have access to", result[:error]
    refute_match "WHERE", result.values.join(" ")
    refute_match "accounts", result[:error]
  end

  test "date errors return the message and a format hint" do
    @function.to_raise = Date::Error.new("invalid date")

    result = call_tool

    assert_equal "invalid date", result[:error]
    assert_match "YYYY-MM-DD", result[:hint]
  end

  test "argument errors return the message, cut to a safe length" do
    @function.to_raise = ArgumentError.new("x" * 2_000)

    result = call_tool

    assert_equal Assistant::FunctionToolCaller::MAX_ERROR_MESSAGE_LENGTH, result[:error].length
    assert_match "retry once", result[:hint]
  end

  test "key errors return the message and a format hint" do
    @function.to_raise = KeyError.new("key not found: \"start_date\"")

    result = call_tool

    assert_equal "key not found: \"start_date\"", result[:error]
    assert_match "YYYY-MM-DD", result[:hint]
  end

  test "validation errors return the record's messages" do
    account = Account.new
    account.errors.add(:name, :blank)
    @function.to_raise = ActiveRecord::RecordInvalid.new(account)

    result = call_tool

    assert_equal "Name can't be blank", result[:error]
    assert_match "Fix the listed fields", result[:hint]
  end

  test "unexpected errors are logged in full and returned without their message" do
    @function.to_raise = RuntimeError.new("PG::ConnectionBad: secret host 10.0.0.1")
    Rails.logger.expects(:error).with { |message| message.include?("PG::ConnectionBad") && message.include?("RuntimeError") }

    result = call_tool

    assert_equal "probe failed unexpectedly", result[:error]
    assert_match "Do not retry", result[:hint]
    refute_match "10.0.0.1", result.values.join(" ")
  end

  test "error_result is shared with other callers" do
    result = Assistant::FunctionToolCaller.error_result("get_accounts", ActiveRecord::RecordNotFound.new("SELECT 1"))

    assert_equal "No such record, or it is not one you have access to", result[:error]
  end

  test "parse_arguments accepts a Hash and stringifies its keys" do
    assert_equal({ "page" => 1 }, Assistant::FunctionToolCaller.parse_arguments({ page: 1 }))
  end

  test "fulfill_requests turns a failing call into a tool call with the error as its result" do
    @function.to_raise = Date::Error.new("invalid date")

    tool_calls = @caller.fulfill_requests([ request(name: "probe", args: "{}") ])

    assert_equal 1, tool_calls.size
    assert_equal "invalid date", tool_calls.first.function_result["error"]
  end

  test "every call is audited with the caller's actor" do
    message = messages(:chat1_assistant_response)
    caller = Assistant::FunctionToolCaller.new([ @function ], actor: Assistant::ToolInvocation::Actor.builtin_chat(message))

    assert_difference -> { AiToolAudit.count }, 1 do
      caller.fulfill_requests([ request(name: "probe", args: '{"page": 2}') ])
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal "builtin_chat", audit.source
    assert_equal "probe", audit.tool_name
    assert_equal message.id, audit.assistant_message_id
    assert_equal message.chat_id, audit.chat_id
    assert_equal({ "page" => 2 }, audit.arguments)
  end

  test "without an actor a call is audited as the built-in chat of the function's user" do
    call_tool

    audit = AiToolAudit.order(:created_at).last
    assert_equal "builtin_chat", audit.source
    assert_equal users(:family_admin), audit.user
    assert_nil audit.assistant_message_id
  end

  test "a failing call is audited as an error" do
    @function.to_raise = Date::Error.new("invalid date")

    call_tool

    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal "invalid date", audit.error_message
  end

  test "an unknown tool runs nothing and is not audited" do
    assert_no_difference -> { AiToolAudit.count } do
      call_tool(name: "drop_tables")
    end
  end

  private
    def call_tool(name: "probe", args: "{}")
      @caller.send(:execute, request(name: name, args: args))
    end

    def request(name:, args:)
      Provider::LlmConcept::ChatFunctionRequest.new(id: "fc_1", call_id: "call_1", function_name: name, function_args: args)
    end
end
