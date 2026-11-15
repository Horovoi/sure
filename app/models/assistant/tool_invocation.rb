# The one place a tool runs, for every channel: the built-in chat (Assistant::FunctionToolCaller), and /mcp with
# the static token (Claude Code) or the per-turn token of the Claude chat (Mcp::ServerBuilder).
#
# Every call is audited in ai_tool_audits, reads included (owner answer 14: no approval prompt, so a log instead):
# 1. Insert a running row with the redacted, capped arguments, before anything else runs.
# 2. For a :write or :destructive tool, store function.audit_before(arguments), the state the call will change.
# 3. Run the tool. A raised error becomes the {error, hint} data FunctionToolCaller.error_result gives; nothing
#    raises out of here.
# 4. In ensure, finish the row: status, error message, the ids the call touched (writes only) and the duration.
#
# The tool's own DB transaction has ended by step 4, so a failed or rolled-back call is logged too. Callers must not
# wrap a call in an outer transaction, or a rollback there would take the audit row with it. The audit never
# changes a tool's result: an audit write that fails is logged and skipped.
class Assistant::ToolInvocation
  # Who is calling. source is builtin_chat (FunctionToolCaller), claude_chat (the Claude chat's turn token) or mcp
  # (the static token, with the MCP clientInfo name).
  Actor = Data.define(:user, :source, :client_name, :chat_id, :assistant_message_id) do
    def initialize(user:, source:, client_name: nil, chat_id: nil, assistant_message_id: nil)
      source = source.to_s
      raise ArgumentError, "Unknown tool-call source: #{source.inspect}" unless AiToolAudit::SOURCES.include?(source)

      super
    end

    def self.builtin_chat(assistant_message)
      new(
        user: assistant_message.chat.user,
        source: "builtin_chat",
        chat_id: assistant_message.chat_id,
        assistant_message_id: assistant_message.id
      )
    end
  end

  def self.call(function, raw_arguments, actor:)
    new(function, actor: actor).call(raw_arguments)
  end

  def initialize(function, actor:)
    @function = function
    @actor = actor
  end

  def call(raw_arguments)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    arguments, parse_error = parse(raw_arguments)
    audit = open_audit(arguments || raw_arguments)

    result = begin
      raise parse_error if parse_error

      record_before(audit, arguments) unless function.class.read_only?
      function.call(arguments)
    rescue => e
      Assistant::FunctionToolCaller.error_result(function.name, e)
    end
  ensure
    close_audit(audit, result, started_at) if audit
  end

  private
    attr_reader :function, :actor

    def parse(raw_arguments)
      [ Assistant::FunctionToolCaller.parse_arguments(raw_arguments), nil ]
    rescue JSON::ParserError, ArgumentError => e
      [ nil, e ]
    end

    def open_audit(arguments)
      user = actor.user

      AiToolAudit.create!(
        family_id: user.family_id,
        user: user,
        source: actor.source,
        client_name: actor.client_name.to_s.truncate(100).presence,
        chat_id: actor.chat_id,
        assistant_message_id: actor.assistant_message_id,
        tool_name: function.name,
        scope_tag: function.scope_tag.to_s,
        arguments: AiToolAudit.storable(arguments) || {},
        status: "running"
      )
    rescue => e
      log_audit_failure("open", e)
      nil
    end

    # The snapshot goes in before the call, so a call that never finishes still shows what it was about to change.
    # A snapshot that fails (the record does not exist, a bad id) is skipped; the tool reports that itself.
    def record_before(audit, arguments)
      before = function.audit_before(arguments)
      return if before.nil? || audit.nil?

      audit.update_columns(audit_before: AiToolAudit.storable(before), updated_at: Time.current)
    rescue => e
      log_audit_failure("snapshot", e)
    end

    def close_audit(audit, result, started_at)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      error = error_of(result)

      attributes = {
        status: error ? "error" : "ok",
        error_message: error&.truncate(AiToolAudit::MAX_ERROR_LENGTH),
        duration_ms: duration_ms,
        finished_at: Time.current,
        updated_at: Time.current
      }

      # A read stores the outcome only; a write also names what it touched, so it can be found and reverted
      unless function.class.read_only?
        attributes[:result_record_type] = function.record_type
        attributes[:result_record_ids] = Array(function.audit_refs(result)).map(&:to_s).uniq
      end

      audit.update_columns(attributes)
    rescue => e
      log_audit_failure("close", e)
    end

    # nil when the call succeeded. A tool that refuses its arguments answers {error:, hint:} (or ImportBankStatement's
    # {success: false, error:}); a result missing because an exception that is not a StandardError cut the call off
    # (a killed job) is an error too.
    def error_of(result)
      return "interrupted" if result.nil?
      return unless result.is_a?(Hash)

      error = result[:error] || result["error"]
      error.to_s.presence if error.present?
    end

    def log_audit_failure(step, exception)
      Rails.logger.error(
        "AI tool audit #{step} failed for #{function.name}: #{exception.class}: #{exception.message}"
      )
    end
end
