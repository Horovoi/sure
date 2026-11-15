class Assistant::FunctionToolCaller
  # Longest exception message handed back to a model for an argument error. Longer ones are cut, so a
  # message that embeds a large input cannot flood the model's context.
  MAX_ERROR_MESSAGE_LENGTH = 500

  class << self
    # The sanitised {error:, hint:} a tool returns instead of raising. The model reads it and can retry once
    # with corrected arguments; the full exception and its backtrace go only to the log (decision 15). The
    # chat (through #execute) and the MCP endpoint (as an isError result) both build their tool errors here.
    def error_result(function_name, exception)
      case exception
      when JSON::ParserError
        log(:warn, function_name, exception)
        {
          error: "Arguments were not valid JSON",
          hint: "Re-send #{function_name} with valid JSON arguments."
        }
      when ActiveRecord::RecordNotFound
        log(:warn, function_name, exception)
        # The raised message carries the scoped relation's SQL, so it never reaches the model. A not-found is
        # deliberately the same answer as a record the user cannot access.
        {
          error: "No such record, or it is not one you have access to",
          hint: "That record was not found. List valid options first (for example get_accounts) and retry once with an exact match."
        }
      when ActiveRecord::RecordInvalid
        log(:warn, function_name, exception)
        # Validation messages name fields and rules, never SQL, and tell the model what to fix
        {
          error: exception.record.errors.full_messages.to_sentence.presence || "The record is not valid",
          hint: "Fix the listed fields and retry once."
        }
      when Date::Error, ArgumentError, KeyError
        log(:warn, function_name, exception)
        {
          error: exception.message.to_s.truncate(MAX_ERROR_MESSAGE_LENGTH),
          hint: "Check argument formats (dates are YYYY-MM-DD) and retry once with corrected arguments."
        }
      else
        log(:error, function_name, exception)
        {
          error: "#{function_name} failed unexpectedly",
          hint: "Do not retry with the same arguments. Answer with the data you already have and note the gap."
        }
      end
    end

    def unknown_tool_result(function_name)
      {
        error: "Unknown tool: #{function_name}",
        hint: "Only call tools from the provided list."
      }
    end

    # Arguments as a Hash with string keys, from a JSON string (chat providers) or a Hash (MCP). Blank arguments
    # mean "no arguments"; anything but a JSON object is an argument error.
    def parse_arguments(raw_arguments)
      parsed = raw_arguments.is_a?(String) ? JSON.parse(raw_arguments.presence || "{}") : raw_arguments
      parsed = {} if parsed.nil?
      raise ArgumentError, "Arguments must be a JSON object" unless parsed.is_a?(Hash)

      parsed.deep_stringify_keys
    end

    private
      def log(level, function_name, exception)
        Rails.logger.public_send(
          level,
          "Assistant tool #{function_name} raised #{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(20).join("\n")}"
        )
      end
  end

  attr_reader :functions

  def initialize(functions = [])
    @functions = functions
  end

  def fulfill_requests(function_requests)
    function_requests.map do |function_request|
      result = execute(function_request)

      ToolCall::Function.from_function_request(function_request, result)
    end
  end

  def function_definitions
    functions.map(&:to_definition)
  end

  private
    # The single entry point for every chat tool call. Tool failures come back as data instead of raising, so one
    # bad call never aborts the turn; the per-call audit log wraps this method.
    def execute(function_request)
      fn = find_function(function_request)
      return self.class.unknown_tool_result(function_request.function_name) if fn.nil?

      fn.call(self.class.parse_arguments(function_request.function_args))
    rescue => e
      self.class.error_result(function_request.function_name, e)
    end

    def find_function(function_request)
      functions.find { |f| f.name == function_request.function_name }
    end
end
