class Assistant::Responder
  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  # Most rounds of function calls one turn may run (each round is one more LLM request), so a model that keeps
  # asking for functions cannot run up spend. A turn that needs more fails, and the chat stays usable.
  MAX_FUNCTION_ROUNDS = 3

  TooManyFunctionRoundsError = Class.new(StandardError)

  # Requests a response, runs the functions it asks for and sends their results back, until the model answers
  # without asking for more functions. Emits :output_text (streamed text) and :function_tool_calls (each round's
  # executed calls). Returns the final response, which has no unresolved function calls, so it is safe to
  # continue the conversation from.
  #
  # Each request returns before the next one starts (nothing runs inside a provider's stream callback), so a
  # failing request is recorded once, by the provider call that failed.
  def respond(previous_response_id: nil)
    response = get_llm_response(previous_response_id: previous_response_id)
    rounds = 0

    while response.function_requests.any?
      rounds += 1
      raise TooManyFunctionRoundsError, "The model asked for functions more than #{MAX_FUNCTION_ROUNDS} times in one turn" if rounds > MAX_FUNCTION_ROUNDS

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)
      emit(:function_tool_calls, function_tool_calls)

      response = get_llm_response(
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id
      )
    end

    response
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def streamer
      @streamer ||= proc do |chunk|
        # The "response" chunk is ignored here: the provider call returns the same response once it finishes
        emit(:output_text, chunk.data) if chunk.type == "output_text"
      end
    end

    def get_llm_response(function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end
end
