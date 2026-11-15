require "test_helper"

class Assistant::ToolInvocationTest < ActiveSupport::TestCase
  class ReadProbe < Assistant::Function
    class << self
      def name
        "read_probe"
      end

      def description
        "Returns a body the audit must not store"
      end
    end

    def call(_params = {})
      { accounts: [ { id: "a1", balance: "123.45" } ] }
    end
  end

  # Renames a tag inside its own transaction, the way write tools do, and can be told to fail inside it
  class WriteProbe < Assistant::Function
    scope_tag :write

    class << self
      def name
        "write_probe"
      end

      def description
        "Renames a tag"
      end
    end

    attr_accessor :fail_inside_transaction, :fail_snapshot

    def call(params = {})
      tag = family.tags.find(params["id"])

      ActiveRecord::Base.transaction do
        tag.update!(name: params["name"])
        raise "boom after the write with secret internals" if fail_inside_transaction
      end

      { id: tag.id, name: tag.name }
    end

    def record_type
      "Tag"
    end

    def audit_before(params)
      raise "snapshot exploded" if fail_snapshot

      tag = family.tags.find_by(id: params["id"])
      tag && { id: tag.id, name: tag.name }
    end
  end

  setup do
    @user = users(:family_admin)
    @tag = tags(:one)
    @actor = Assistant::ToolInvocation::Actor.new(user: @user, source: "mcp", client_name: "claude-code")
  end

  test "a write call writes one row with who, arguments, result ids and the before snapshot" do
    old_name = @tag.name

    assert_difference -> { AiToolAudit.count }, 1 do
      result = invoke(WriteProbe, { "id" => @tag.id, "name" => "Renamed" })
      assert_equal "Renamed", result[:name]
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal @user.family, audit.family
    assert_equal @user, audit.user
    assert_equal "mcp", audit.source
    assert_equal "claude-code", audit.client_name
    assert_equal "write_probe", audit.tool_name
    assert_equal "write", audit.scope_tag
    assert_equal({ "id" => @tag.id, "name" => "Renamed" }, audit.arguments)
    assert_equal({ "id" => @tag.id, "name" => old_name }, audit.audit_before)
    assert_equal "ok", audit.status
    assert_nil audit.error_message
    assert_equal "Tag", audit.result_record_type
    assert_equal [ @tag.id ], audit.result_record_ids
    assert audit.duration_ms >= 0
    assert audit.finished_at.present?
  end

  test "a read call stores the outcome only, never the result body" do
    invoke(ReadProbe, {})

    audit = AiToolAudit.order(:created_at).last
    assert_equal "read_probe", audit.tool_name
    assert_equal "read", audit.scope_tag
    assert_equal "ok", audit.status
    assert_nil audit.audit_before
    assert_nil audit.result_record_type
    assert_equal [], audit.result_record_ids
    refute_match "123.45", audit.attributes.to_json
  end

  test "a tool that raises writes an error row and the error still comes back as data" do
    result = invoke(WriteProbe, { "id" => @tag.id, "name" => "Renamed" }) { |function| function.fail_inside_transaction = true }

    assert_equal "write_probe failed unexpectedly", result[:error]
    assert result[:hint].present?

    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal "write_probe failed unexpectedly", audit.error_message
    refute_match "secret internals", audit.error_message
  end

  test "a call whose transaction rolls back still leaves its row" do
    old_name = @tag.name

    invoke(WriteProbe, { "id" => @tag.id, "name" => "Rolled back" }) { |function| function.fail_inside_transaction = true }

    assert_equal old_name, @tag.reload.name
    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal({ "id" => @tag.id, "name" => old_name }, audit.audit_before)
  end

  test "the row is written as running before the tool runs" do
    statuses = []
    WriteProbe.any_instance.stubs(:call).with { statuses << AiToolAudit.order(:created_at).last&.status; true }.returns({ id: @tag.id })

    invoke(WriteProbe, { "id" => @tag.id, "name" => "x" })

    assert_equal [ "running" ], statuses
    assert_equal "ok", AiToolAudit.order(:created_at).last.status
  end

  test "a soft error result counts as an error" do
    ReadProbe.any_instance.stubs(:call).returns({ error: "invalid_account_id", hint: "Use an id from get_accounts" })

    invoke(ReadProbe, {})

    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal "invalid_account_id", audit.error_message
  end

  test "invalid JSON arguments are audited as an error with the raw text" do
    result = Assistant::ToolInvocation.call(ReadProbe.new(@user), "{not json", actor: @actor)

    assert_equal "Arguments were not valid JSON", result[:error]
    audit = AiToolAudit.order(:created_at).last
    assert_equal "error", audit.status
    assert_equal({ "_raw" => "{not json" }, audit.arguments)
  end

  test "a failing snapshot does not stop the call" do
    result = invoke(WriteProbe, { "id" => @tag.id, "name" => "Still renamed" }) { |function| function.fail_snapshot = true }

    assert_equal "Still renamed", result[:name]
    audit = AiToolAudit.order(:created_at).last
    assert_equal "ok", audit.status
    assert_nil audit.audit_before
  end

  test "an audit write that fails never changes the tool result" do
    AiToolAudit.stubs(:create!).raises(ActiveRecord::StatementInvalid, "PG::UndefinedTable")
    Rails.logger.expects(:error).with { |message| message.include?("AI tool audit open failed") }

    result = invoke(WriteProbe, { "id" => @tag.id, "name" => "No audit" })

    assert_equal "No audit", result[:name]
    assert_equal "No audit", @tag.reload.name
  end

  test "secrets in the arguments are redacted" do
    invoke(ReadProbe, { "api_token" => "sk-live-123", "query" => "coffee" })

    arguments = AiToolAudit.order(:created_at).last.arguments
    assert_equal "[FILTERED]", arguments["api_token"]
    assert_equal "coffee", arguments["query"]
  end

  test "large arguments are capped with a truncated marker" do
    invoke(ReadProbe, { "notes" => "x" * 40.kilobytes })

    audit = AiToolAudit.order(:created_at).last
    assert audit.truncated_arguments?
    assert audit.arguments.to_json.bytesize <= AiToolAudit::MAX_JSON_BYTES
    assert audit.arguments["_bytes"] > AiToolAudit::MAX_JSON_BYTES
  end

  test "the actor's chat and message are stored as plain ids" do
    message = messages(:chat1_assistant_response)
    actor = Assistant::ToolInvocation::Actor.builtin_chat(message)

    Assistant::ToolInvocation.call(ReadProbe.new(message.chat.user), {}, actor: actor)

    audit = AiToolAudit.order(:created_at).last
    assert_equal "builtin_chat", audit.source
    assert_equal message.chat_id, audit.chat_id
    assert_equal message.id, audit.assistant_message_id
  end

  test "an unknown source is refused" do
    assert_raises(ArgumentError) { Assistant::ToolInvocation::Actor.new(user: @user, source: "openclaw") }
  end

  test "one write through each channel writes one row each" do
    message = messages(:chat1_assistant_response)
    function = WriteProbe.new(@user)

    assert_difference -> { AiToolAudit.count }, 3 do
      # Built-in chat
      Assistant::FunctionToolCaller.new([ function ], actor: Assistant::ToolInvocation::Actor.builtin_chat(message))
        .fulfill_requests([ function_request("write_probe", { id: @tag.id, name: "From chat" }.to_json) ])

      # Claude chat through its turn token, and Claude Code through the static token
      Mcp::ServerBuilder.new(Mcp::Credential.turn(@user, assistant_message: message, client_name: "sure-claude-chat"))
        .call_tool(WriteProbe, { "id" => @tag.id, "name" => "From Claude chat" })
      Mcp::ServerBuilder.new(Mcp::Credential.static(@user, client_name: "claude-code"))
        .call_tool(WriteProbe, { "id" => @tag.id, "name" => "From Claude Code" })
    end

    audits = AiToolAudit.where(tool_name: "write_probe").order(:created_at).last(3)
    assert_equal %w[builtin_chat claude_chat mcp], audits.map(&:source)
    assert_equal [ message.id, message.id, nil ], audits.map(&:assistant_message_id)
    assert_equal [ nil, "sure-claude-chat", "claude-code" ], audits.map(&:client_name)
    assert(audits.all? { |audit| audit.result_record_ids == [ @tag.id ] })
  end

  private
    def invoke(function_class, arguments)
      function = function_class.new(@user)
      yield function if block_given?
      Assistant::ToolInvocation.call(function, arguments, actor: @actor)
    end

    def function_request(name, args)
      Provider::LlmConcept::ChatFunctionRequest.new(id: "fc_1", call_id: "call_1", function_name: name, function_args: args)
    end
end
