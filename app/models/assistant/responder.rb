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
  # asking for functions cannot run up spend. Rounds, not calls: parallel calls in one round count once.
  # Override with ASSISTANT_MAX_FUNCTION_ROUNDS.
  MAX_FUNCTION_ROUNDS = 6

  TooManyFunctionRoundsError = Class.new(StandardError)
  EmptyResponseError = Class.new(StandardError)

  def self.max_function_rounds
    configured = Integer(ENV.fetch("ASSISTANT_MAX_FUNCTION_ROUNDS", MAX_FUNCTION_ROUNDS).to_s, 10)
    configured.positive? ? configured : MAX_FUNCTION_ROUNDS
  rescue ArgumentError
    MAX_FUNCTION_ROUNDS
  end

  # Requests a response, runs the functions it asks for and sends their results back, until the model answers
  # without asking for more functions. Emits :output_text (streamed text) and :function_tool_calls (each round's
  # executed calls). Returns the final response, which has no unresolved function calls, so it is safe to
  # continue the conversation from.
  #
  # The follow-up after the last permitted round sends tool_choice :none, so the model answers in text with
  # what it gathered instead of the turn failing. The tool definitions stay in that request: some providers
  # reject a conversation holding tool calls when no tools are defined. A model that still asks for functions
  # raises TooManyFunctionRoundsError, as a backstop. A turn that ends with no text at all raises
  # EmptyResponseError, so it fails (and can be retried) instead of completing blank.
  #
  # Each request returns before the next one starts (nothing runs inside a provider's stream callback), so a
  # failing request is recorded once, by the provider call that failed.
  def respond(previous_response_id: nil)
    max_rounds = self.class.max_function_rounds
    response = get_llm_response(previous_response_id: previous_response_id)
    rounds = 0

    while response.function_requests.any?
      rounds += 1
      raise TooManyFunctionRoundsError, "The model asked for functions more than #{max_rounds} times in one turn" if rounds > max_rounds

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)
      emit(:function_tool_calls, function_tool_calls)

      response = get_llm_response(
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id,
        tool_choice: rounds == max_rounds ? :none : nil
      )
    end

    raise EmptyResponseError, "The model returned no text" unless any_text?

    response
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def any_text?
      @any_text || false
    end

    def streamer
      @streamer ||= proc do |chunk|
        # The "response" chunk is ignored here: the provider call returns the same response once it finishes
        if chunk.type == "output_text" && !chunk.data.to_s.empty?
          @streamed_this_request = true
          stream_text(chunk.data.to_s)
        end
      end
    end

    # A whitespace-only chunk is real text (OpenAI streams the space before a number as its own chunk), but a
    # turn whose content is only whitespace cannot complete, so leading whitespace is held back until the first
    # non-blank chunk and emitted together with it. Whitespace that no text follows is dropped.
    def stream_text(text)
      if any_text?
        emit(:output_text, text)
      elsif text.blank?
        held_whitespace << text
      else
        @any_text = true
        emit(:output_text, held_whitespace + text)
        held_whitespace.clear
      end
    end

    def held_whitespace
      @held_whitespace ||= +""
    end

    def get_llm_response(function_results: [], previous_response_id: nil, tool_choice: nil)
      @streamed_this_request = false

      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        tool_choice: tool_choice,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      # A provider that answers without streaming its text still gets that text into the turn
      unless @streamed_this_request
        text = response.data.messages.map(&:output_text).compact.join
        stream_text(text) unless text.empty?
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
