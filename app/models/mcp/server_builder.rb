# Builds the MCP server for one /mcp request (protocol 2026-07-28, stateless: nothing outlives the request).
# Every Assistant function in the credential's scope is one MCP tool, in the order of Assistant.function_classes,
# which is also the order the in-app chat sees. Both tokens have scope :full, so MCP and the chat serve one tool
# set (owner answer 14).
class Mcp::ServerBuilder
  SERVER_NAME = "sure".freeze

  # tools/list and server/discover may be cached by the client for this long. The tool set is fixed and no schema
  # holds family data any more, but the instructions and some descriptions name the family's currency, time zone
  # and today's date, so the cache is short and private to the token.
  LIST_TTL_MS = 60_000
  CACHE_SCOPE = "private".freeze

  def self.build(credential)
    new(credential).build
  end

  def initialize(credential)
    @credential = credential
  end

  def build
    MCP::Server.new(
      name: SERVER_NAME,
      title: "Sure",
      version: Sure.version.to_s,
      instructions: instructions,
      tools: tools,
      capabilities: { tools: {} },
      ttl_ms: LIST_TTL_MS,
      cache_scope: CACHE_SCOPE,
      configuration: configuration
    )
  end

  def tools
    function_classes.map { |function_class| tool_for(function_class) }
  end

  # The one place an MCP tool call runs, through Assistant::ToolInvocation, which audits it under the credential's
  # channel (mcp for the static token, claude_chat for the Claude chat's turn token). A tool error is a result with
  # isError (the model reads it and can retry); protocol problems (unknown tool, arguments that break the schema)
  # are refused by the SDK before this runs, so they are not audited.
  def call_tool(function_class, arguments)
    function = function_class.new(user)
    result = Assistant::ToolInvocation.call(function, arguments, actor: credential.audit_actor)

    # A tool that refuses the arguments answers {error, hint} without raising; that is a tool error too
    tool_response(result, error: result.is_a?(Hash) && result.key?(:error))
  rescue => e
    tool_response(Assistant::FunctionToolCaller.error_result(function_class.name, e), error: true)
  end

  private
    attr_reader :credential

    # The credential's scope picks the tools. A tool outside it is not registered, so tools/list leaves it out and
    # tools/call answers it as an unknown tool (-32602).
    def function_classes
      credential.function_classes
    end

    def user
      credential.user
    end

    def family
      credential.family
    end

    def tool_for(function_class)
      function = function_class.new(user)
      builder = self

      MCP::Tool.define(
        name: function.name,
        title: function.title,
        description: function.description.to_s.strip,
        input_schema: function.mcp_input_schema,
        annotations: function.mcp_annotations
      ) do |server_context:, **arguments|
        builder.call_tool(function_class, arguments)
      end
    end

    def tool_response(result, error: false)
      # Round-trip through JSON so structuredContent holds exactly what the text block says
      json = result.to_json
      MCP::Tool::Response.new(
        [ { type: "text", text: json } ],
        error: error,
        structured_content: JSON.parse(json)
      )
    end

    def configuration
      MCP::Configuration.new(
        exception_reporter: ->(exception, _context) { report_exception(exception) },
        validate_tool_call_arguments: true
      )
    end

    # The SDK reports protocol errors (unknown tool, invalid params) and failures outside a tool. The client
    # gets a generic message; the log keeps the detail.
    def report_exception(exception)
      if exception.is_a?(MCP::Server::RequestHandlerError) && exception.error_type != :internal_error
        Rails.logger.info("MCP request error: #{exception.message}")
      else
        Rails.logger.error("MCP error: #{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(20).join("\n")}")
      end
    end

    def instructions
      currency = family.currency
      lines = [
        "Sure is a personal finance app for one family. Every account is entered by hand; there are no bank connections.",
        "Amounts are in #{currency} unless a result names another currency. Other currencies convert at the official National Bank of Ukraine (NBU) rates.",
        "Dates are calendar dates in the family time zone (#{family.timezone.presence || Time.zone.tzinfo.identifier}); 'today' and 'this month' follow that zone.",
        fiscal_month_line,
        "Use the tools to read data before answering. A tool error comes back as a result with an error and a hint: fix the arguments and retry once, or answer with what you have."
      ]

      lines.compact.join("\n")
    end

    def fiscal_month_line
      return unless family.fiscal_month_enabled?

      "Budget months are fiscal months that start on day #{family.fiscal_start_day} of each calendar month."
    end
end
