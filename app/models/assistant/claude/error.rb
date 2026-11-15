# A Claude turn that cannot finish. The message is written for the owner and says what to do (the reset time of a
# used-up usage window in the family time zone, or the bin/claude-bridge command that finds the problem).
# AssistantMessage#generate_response fails the turn with it, and the chat shows it next to Retry.
#
# Codes: the bridge's own (auth, usage_limit, overloaded, session_not_found, mcp_unavailable, timeout, budget,
# max_turns, busy, internal) and the ones Sure finds itself (not_configured, unreachable, unauthorized,
# bad_request, bad_response, incomplete, empty).
class Assistant::Claude::Error < StandardError
  BRIDGE_CODES = %w[auth usage_limit overloaded session_not_found mcp_unavailable timeout budget max_turns busy internal].freeze
  LOCAL_CODES = %w[not_configured unreachable unauthorized bad_request bad_response incomplete empty].freeze
  CODES = (BRIDGE_CODES + LOCAL_CODES).freeze

  attr_reader :code, :reset_at

  # An "error" line from the bridge, or the body of a refused request (401, 400, 429)
  def self.from_event(event, time_zone: nil)
    event = event.is_a?(Hash) ? event : {}
    code = event["code"].to_s
    code = "bad_request" if %w[bad_request mcp_url_not_allowed not_found].include?(code)
    code = "internal" unless CODES.include?(code)

    new(code, detail: event["message"], reset_at: event["reset_at"], time_zone: time_zone)
  end

  def initialize(code, detail: nil, reset_at: nil, time_zone: nil)
    @code = code.to_s
    @detail = detail.to_s.squish.truncate(300).presence
    @reset_at = parse_time(reset_at)
    @time_zone = time_zone

    super(build_message)
  end

  def retry_fresh?
    code == "session_not_found"
  end

  # Stored in chat.error. The chat shows the message of a user-facing error even outside debug mode.
  def as_json(*)
    { "message" => message, "code" => code, "user_facing" => true }
  end

  private
    attr_reader :detail, :time_zone

    def build_message
      case code
      when "usage_limit"
        if reset_at
          I18n.t("assistant.claude.errors.usage_limit_with_reset", time: formatted_reset_at)
        else
          I18n.t("assistant.claude.errors.usage_limit")
        end
      when "internal", "bad_request", "bad_response", "mcp_unavailable"
        base = I18n.t("assistant.claude.errors.#{code}")
        detail ? "#{base} (#{detail})" : base
      else
        I18n.t("assistant.claude.errors.#{code}", default: I18n.t("assistant.claude.errors.internal"))
      end
    end

    def parse_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # In the family time zone (Kyiv), with the date only when the window does not reset today
    def formatted_reset_at
      zone = ActiveSupport::TimeZone[time_zone.to_s] || Time.zone
      local = reset_at.in_time_zone(zone)
      format = local.to_date == zone.today ? "%H:%M" : "%b %-d, %H:%M"

      "#{local.strftime(format)} (#{zone.tzinfo.identifier})"
    end
end
