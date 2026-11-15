# The Claude card on Settings > AI: usage windows from the bridge's /health (utilization 0-1, resets_at ISO 8601)
module ClaudeStatusHelper
  # The windows the card shows, in this order, when the bridge reports them
  CLAUDE_USAGE_WINDOWS = %w[five_hour seven_day].freeze

  def claude_usage_windows(status)
    usage = status["usage"]
    return [] unless usage.is_a?(Hash) && usage["available"]

    CLAUDE_USAGE_WINDOWS.filter_map do |name|
      window = usage[name]
      next unless window.is_a?(Hash)

      utilization = window["utilization"]
      percent = utilization.is_a?(Numeric) ? (utilization * 100).round.clamp(0, 100) : nil
      { name: name, percent: percent, resets_at: window["resets_at"] }
    end
  end

  # "Nov 15, 14:20" in the family time zone (Kyiv), or nil for a missing or unreadable time
  def claude_reset_time(iso_time, time_zone)
    return if iso_time.blank?

    zone = ActiveSupport::TimeZone[time_zone.to_s] || Time.zone
    Time.iso8601(iso_time.to_s).in_time_zone(zone).strftime("%b %-d, %H:%M")
  rescue ArgumentError
    nil
  end

  def claude_usage_bar_class(percent)
    return "bg-gray-400" if percent.nil?
    return "bg-destructive" if percent >= 90
    return "bg-warning" if percent >= 70

    "bg-success"
  end
end
