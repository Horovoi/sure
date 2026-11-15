# One AI tool call: who made it (user, channel, client, chat message), which tool with which arguments, how it
# ended, and for a write the ids it touched plus the record's state before the call. Every tool runs with no
# approval prompt (owner answer 14); this log is how a wrong call is found and reverted by hand.
#
# Rows are written only by Assistant::ToolInvocation: inserted as running before the tool runs, finished after it
# (so a crash mid-call still leaves a row). The result body is never stored, nor any prompt or model answer.
class AiToolAudit < ApplicationRecord
  SOURCES = %w[builtin_chat claude_chat mcp].freeze
  STATUSES = %w[running ok error].freeze

  # Largest JSON stored for the arguments or the before snapshot; anything larger is cut with a marker
  MAX_JSON_BYTES = 16.kilobytes
  MAX_ERROR_LENGTH = 500

  # A running row this old was cut off (the process died or the job was killed mid-call)
  INTERRUPTED_AFTER = 1.hour

  belongs_to :family
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :scope_tag, inclusion: { in: Assistant::Function::SCOPE_TAGS.map(&:to_s) }
  validates :tool_name, presence: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :writes, -> { where(scope_tag: %w[write destructive]) }
  scope :for_tool, ->(tool_name) { where(tool_name: tool_name) }

  class << self
    # Arguments or a snapshot as stored: secrets redacted with the app's filter_parameters (the same list the
    # request log uses), then round-tripped through JSON and capped at MAX_JSON_BYTES.
    def storable(value)
      return nil if value.nil?

      json = parameter_filter.filter(normalize(value)).to_json
      return JSON.parse(json) if json.bytesize <= MAX_JSON_BYTES

      # Encoding the preview again escapes its quotes and backslashes, up to doubling it, so half the cap is kept
      { "_truncated" => true, "_bytes" => json.bytesize, "preview" => json.byteslice(0, MAX_JSON_BYTES / 2 - 512).scrub("") }
    end

    private
      def parameter_filter
        ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      end

      # ParameterFilter walks Hashes; a bare value (an unparsable argument string) is wrapped so it is filtered and
      # capped the same way
      def normalize(value)
        value.is_a?(Hash) ? JSON.parse(value.to_json) : { "_raw" => value.to_s }
      end
  end

  def write?
    scope_tag.in?(%w[write destructive])
  end

  def running?
    status == "running"
  end

  def ok?
    status == "ok"
  end

  def error?
    status == "error"
  end

  # What the settings page shows: a row left running long ago never finished
  def display_status
    running? && created_at < INTERRUPTED_AFTER.ago ? "interrupted" : status
  end

  def truncated_arguments?
    arguments.is_a?(Hash) && arguments["_truncated"] == true
  end
end
