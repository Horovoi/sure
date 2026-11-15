# Answers a chat turn with Claude, through the bridge on the Mac (claude_bridge/server.ts) that runs Claude Code
# with the owner's own Claude login. Assistant#respond_to sends a turn here when its model is a Claude model.
#
# One turn:
# 1. Mint the turn's /mcp token (Mcp::TurnToken): Claude Code calls Sure's tools with it, every tool with no
#    approval prompt (owner answer 2), each call audited as claude_chat with this message's id.
# 2. Continue the conversation: resume the Claude Code session of the last completed Claude turn (the bridge
#    forks it, so a failed turn never becomes part of the conversation). With no such turn, or when the bridge no
#    longer has the session, start a fresh session and send the last completed messages as a transcript.
# 3. Stream the bridge's events into the message: text, tool calls, heartbeats (progress for the stale rule).
# 4. On the result, record the usage (llm_usages, provider claude_subscription, API-equivalent cost) and complete
#    the turn with the new session id. chat.latest_assistant_response_id stays the OpenAI pointer.
#
# Anything that goes wrong raises Assistant::Claude::Error with a message the owner can act on;
# AssistantMessage#generate_response fails the turn with it and the chat offers Retry.
class Assistant::Claude
  include Assistant::Broadcastable

  # Claude Code's model aliases. Full ids ("claude-sonnet-5-5") are Claude models too.
  MODEL_ALIASES = %w[opus sonnet haiku].freeze
  FALLBACK_MODELS = MODEL_ALIASES
  DEFAULT_MODEL = "sonnet".freeze
  TOOL_PREFIX = "mcp__sure__".freeze
  # Completed messages sent as a transcript when a turn cannot resume a session
  TRANSCRIPT_MESSAGES = 20
  MAX_TOOL_ROUNDS = 16
  # Under AssistantMessage::STALE_AFTER, so the reaper never fails a turn the bridge still runs
  TURN_TIMEOUT = 8.minutes
  MODELS_CACHE_KEY = "claude_bridge/models/v1".freeze
  MODELS_CACHE_TTL = 10.minutes

  # Appended to the shared chat instructions: what is different when Claude Code answers
  CLAUDE_INSTRUCTIONS = <<~PROMPT.freeze
    ## Tools in this chat

    Your tools are Sure's own tools (named mcp__sure__<tool>). They read and change this family's data directly, and every call is logged.
    When the user asks for a change, make it with the tools and then say what changed. You have no shell, file or web tools.
  PROMPT

  class << self
    def handles?(model)
      name = model.to_s.strip.downcase.sub(/\[.*\]\z/, "")
      name.start_with?("claude") || MODEL_ALIASES.any? { |model_alias| name == model_alias || name.start_with?("#{model_alias}-", "#{model_alias}plan") }
    end

    # Both bridge variables are set (bin/claude-bridge install prints them for .env.production)
    def configured?
      bridge_url.present? && bridge_token.present?
    end

    def bridge_url
      ENV["CLAUDE_BRIDGE_URL"].presence
    end

    def bridge_token
      ENV["CLAUDE_BRIDGE_TOKEN"].presence
    end

    # Sure's /mcp as Claude Code on the Mac sees it: the published port on localhost (production 3333, bin/dev
    # 3000). It must be on the bridge's allowlist (claude_bridge/server.ts DEFAULT_MCP_ALLOWLIST).
    def mcp_url
      ENV["CLAUDE_BRIDGE_MCP_URL"].presence || "http://localhost:#{ENV.fetch("PORT", "3000")}/mcp"
    end

    def client(time_zone: nil)
      Assistant::Claude::Client.new(url: bridge_url, token: bridge_token, time_zone: time_zone)
    end

    # The bridge's /health, or { "ok" => false, "error" => {...} } when it cannot be reached. Never raises.
    def status(time_zone: nil)
      return { "ok" => false, "configured" => false } unless configured?

      client(time_zone: time_zone).health.merge("configured" => true)
    rescue Assistant::Claude::Error => e
      { "ok" => false, "configured" => true, "error" => { "code" => e.code, "message" => e.message } }
    end

    # [[label, value]] for the chat model select: the bridge's models (cached 10 minutes), else the aliases.
    # Only models this adapter handles, so a choice never routes to the wrong engine.
    def model_options
      return [] unless configured?

      models = Rails.cache.fetch(MODELS_CACHE_KEY, expires_in: MODELS_CACHE_TTL, skip_nil: true) { fetch_models }
      models = FALLBACK_MODELS.map { |value| { "value" => value, "display_name" => value.capitalize } } if models.blank?

      models.filter_map do |model|
        value = model["value"].to_s
        next unless handles?(value)

        [ model["display_name"].presence || value, value ]
      end
    end

    private
      def fetch_models
        models = Array(client.models["models"]).select { |model| model.is_a?(Hash) && model["value"].present? }
        models.presence
      rescue Assistant::Claude::Error
        nil
      end
  end

  attr_reader :chat, :instructions

  def initialize(chat, instructions: nil)
    @chat = chat
    @instructions = instructions
  end

  # Streams the answer into a claimed (streaming) assistant message and completes it. Raises on failure.
  def respond_to(assistant_message)
    prompt = assistant_message.prompt
    raise StandardError, "No user message to respond to" unless prompt
    raise Assistant::Claude::Error.new("not_configured") unless self.class.configured?

    @assistant_message = assistant_message
    @rate_limits = []
    @tool_calls = {}

    resume_id = resume_session_id
    begin
      run_turn(prompt, resume_session_id: resume_id)
    rescue Assistant::Claude::Error => e
      # The bridge no longer has the session (cleaned up, another Mac): start over with a transcript, once
      raise unless e.retry_fresh? && resume_id && nothing_streamed?

      resume_id = nil
      retry
    end
  end

  private
    attr_reader :assistant_message

    def run_turn(prompt, resume_session_id:)
      result = nil

      # The bridge ends the stream right after the result or error line
      client.turn(turn_body(prompt, resume_session_id)) do |event|
        result = handle(event) || result
      end

      raise Assistant::Claude::Error.new("incomplete", time_zone: time_zone) unless result

      finish(result)
    end

    def handle(event)
      case event["type"]
      when "text" then append_text(event["delta"].to_s)
      when "tool" then start_tool_call(event)
      when "tool_result" then finish_tool_call(event)
      when "heartbeat" then record_progress
      when "rate_limit" then @rate_limits << event.slice("kind", "utilization", "resets_at", "status")
      when "error" then raise Assistant::Claude::Error.from_event(event, time_zone: time_zone)
      when "result" then return event
      end

      nil
    end

    # A turn whose text is only whitespace cannot complete, so leading whitespace is dropped
    def append_text(delta)
      delta = delta.lstrip if assistant_message.content.blank?
      assistant_message.append_text!(delta) unless delta.empty?
    end

    # Saved as soon as Claude asks for the tool, so the call stays with the turn even if the turn fails later
    def start_tool_call(event)
      update_thinking(I18n.t("assistant.thinking.analyzing"))

      id = event["id"].to_s.presence || SecureRandom.uuid
      @tool_calls[id] = ToolCall::Function.create!(
        message: assistant_message,
        provider_id: id,
        provider_call_id: id,
        function_name: event["name"].to_s.delete_prefix(TOOL_PREFIX),
        function_arguments: event["input"].is_a?(Hash) ? event["input"] : {},
        function_result: { "status" => "running" }
      )
    end

    def finish_tool_call(event)
      tool_call = @tool_calls[event["id"].to_s] || assistant_message.tool_calls.find_by(provider_id: event["id"].to_s)
      return unless tool_call

      content = event["content"].to_s
      result = begin
        JSON.parse(content)
      rescue JSON::ParserError
        { "text" => content }
      end
      result = { "result" => result } unless result.is_a?(Hash)
      result["is_error"] = true if event["is_error"]

      tool_call.update!(function_result: result.presence || { "status" => "done" })
    end

    # The stale rule reads updated_at; a heartbeat moves it without a broadcast
    def record_progress
      assistant_message.update_column(:updated_at, Time.current)
    end

    def finish(result)
      record_usage(result)
      raise Assistant::Claude::Error.new("empty", time_zone: time_zone) if assistant_message.content.blank?

      assistant_message.complete!(result["session_id"].presence)
    end

    def nothing_streamed?
      assistant_message.content.blank? && assistant_message.tool_calls.none?
    end

    # The provider_id of the last completed turn, when that turn was Claude's. An OpenAI turn in between means
    # the Claude session misses part of the conversation, so the turn starts fresh with a transcript instead.
    def resume_session_id
      previous = chat.messages
        .where(type: "AssistantMessage", status: "complete")
        .where("created_at < ?", assistant_message.created_at)
        .where.not(id: assistant_message.id)
        .ordered
        .last

      previous.provider_id.presence if previous && self.class.handles?(previous.ai_model)
    end

    def turn_body(prompt, resume_session_id)
      {
        turn_id: assistant_message.id,
        model: assistant_message.ai_model,
        system_prompt: system_prompt,
        prompt: resume_session_id ? prompt.content : prompt_with_transcript(prompt),
        resume_session_id: resume_session_id,
        mcp: { url: self.class.mcp_url, token: Mcp::TurnToken.generate(assistant_message) },
        limits: { max_turns: MAX_TOOL_ROUNDS, timeout_s: TURN_TIMEOUT.to_i }
      }
    end

    def system_prompt
      [ instructions.presence || Assistant.instructions_for(chat.user), CLAUDE_INSTRUCTIONS ].join("\n")
    end

    def prompt_with_transcript(prompt)
      earlier = chat.messages
        .where(type: %w[UserMessage AssistantMessage])
        .where("created_at < ?", prompt.created_at)
        .where("type = 'UserMessage' OR status = 'complete'")
        .order(created_at: :desc)
        .limit(TRANSCRIPT_MESSAGES)
        .to_a
        .reverse

      return prompt.content if earlier.empty?

      lines = earlier.map do |message|
        speaker = message.is_a?(UserMessage) ? "User" : "Assistant"
        "#{speaker}: #{message.content}"
      end

      <<~PROMPT
        <earlier_conversation>
        #{lines.join("\n\n")}
        </earlier_conversation>

        #{prompt.content}
      PROMPT
    end

    # Claude turns run on the subscription: the row shows the API-equivalent cost of the tokens and stays out of
    # the spend totals (LlmUsage.billed). `usage` covers this turn only; total_cost_usd would include the earlier
    # turns of a resumed session, so the cost is priced from the tokens.
    def record_usage(result)
      usage = result["usage"].is_a?(Hash) ? result["usage"] : {}
      model = result["model"].presence || assistant_message.ai_model
      input = usage["input_tokens"].to_i
      cache_creation = usage["cache_creation_input_tokens"].to_i
      cache_read = usage["cache_read_input_tokens"].to_i
      output = usage["output_tokens"].to_i
      prompt_tokens = input + cache_creation + cache_read

      family.llm_usages.create!(
        provider: LlmUsage::SUBSCRIPTION_PROVIDER,
        model: model,
        operation: "chat",
        prompt_tokens: prompt_tokens,
        completion_tokens: output,
        total_tokens: prompt_tokens + output,
        estimated_cost: LlmUsage.calculate_cost(
          model: model,
          prompt_tokens: input,
          completion_tokens: output,
          cache_creation_tokens: cache_creation,
          cache_read_tokens: cache_read
        ),
        metadata: {
          "billing" => "subscription",
          "cost_basis" => "api_equivalent",
          "chat_id" => chat.id,
          "assistant_message_id" => assistant_message.id,
          "session_id" => result["session_id"],
          "num_turns" => result["num_turns"],
          "duration_ms" => result["duration_ms"],
          "input_tokens" => input,
          "cache_creation_tokens" => cache_creation,
          "cache_read_tokens" => cache_read,
          "rate_limits" => @rate_limits
        }.compact
      )
    rescue => e
      Rails.logger.error("Failed to record Claude usage for message #{assistant_message.id}: #{e.class}: #{e.message}")
    end

    def client
      @client ||= self.class.client(time_zone: time_zone)
    end

    def family
      chat.user.family
    end

    def time_zone
      family.timezone.presence || "Europe/Kyiv"
    end
end
