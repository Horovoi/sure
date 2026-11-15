class Provider::Openai::ChatStreamParser
  Error = Class.new(StandardError)

  # What a stream that ended without a completed response reported: the event, its message and code, and the
  # raw payload
  StreamErrorData = Data.define(:event, :message, :code, :details)

  def initialize(object)
    @object = object
  end

  def parsed
    type = object.dig("type")

    case type
    when "response.output_text.delta", "response.refusal.delta"
      Chunk.new(type: "output_text", data: object.dig("delta"), usage: nil)
    when "response.completed"
      raw_response = object.dig("response")
      usage = raw_response.dig("usage")
      Chunk.new(type: "response", data: parse_response(raw_response), usage: usage)
    when "response.failed", "response.incomplete"
      Chunk.new(type: "error", data: build_response_error(type), usage: nil)
    when "error"
      Chunk.new(
        type: "error",
        data: StreamErrorData.new(
          event: "error",
          message: object.dig("message").presence || "OpenAI stream returned an error event",
          code: object.dig("code"),
          details: object
        ),
        usage: nil
      )
    end
  end

  private
    attr_reader :object

    Chunk = Provider::LlmConcept::ChatStreamChunk

    def parse_response(response)
      Provider::Openai::ChatParser.new(response).parsed
    end

    def build_response_error(event)
      raw_response = object.dig("response") || {}
      message =
        raw_response.dig("error", "message").presence ||
        raw_response.dig("incomplete_details", "reason").presence ||
        "OpenAI stream ended with #{event}"
      code = raw_response.dig("error", "code") || raw_response.dig("incomplete_details", "reason")

      StreamErrorData.new(event: event, message: message, code: code, details: raw_response)
    end
end
