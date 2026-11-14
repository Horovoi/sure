# One assistant turn in a chat. The message is created as `pending` together with the user's prompt, a job
# claims it (`streaming`), and it ends `complete` or `failed`. A failed turn can be retried (`requeue`).
class AssistantMessage < Message
  include AASM

  # A turn with no progress for this long is treated as lost (its job died); the stale work reaper fails it.
  # Each provider request times out after OPENAI_REQUEST_TIMEOUT (60s by default), so a live turn never stays
  # silent this long.
  STALE_AFTER = 10.minutes
  IN_FLIGHT_STATES = %w[pending streaming].freeze

  Error = Class.new(StandardError)
  AiDisabledError = Class.new(Error)
  StaleTurnError = Class.new(Error)

  # The column default ("complete") stays for the other message types; a new assistant message is a new turn.
  attribute :status, :string, default: "pending"
  attribute :content, :string, default: ""

  validates :ai_model, presence: true

  scope :in_flight, -> { where(status: IN_FLIGHT_STATES) }
  scope :stale, -> { in_flight.where(updated_at: ...STALE_AFTER.ago) }

  aasm column: :status, requires_lock: true, whiny_persistence: true do
    state :pending, initial: true
    state :streaming
    state :complete
    state :failed

    event :start do
      transitions from: :pending, to: :streaming
    end

    # complete!(provider_response_id)
    event :complete do
      transitions from: :streaming, to: :complete, after: :move_response_pointer
    end

    # fail!(error) — also the terminal event for the stale work reaper
    event :fail do
      transitions from: %i[pending streaming], to: :failed, after: :record_error
    end

    event :requeue do
      transitions from: :failed, to: :pending, after: :reset_attempt
    end
  end

  def role
    "assistant"
  end

  def in_flight?
    pending? || streaming?
  end

  def stale?
    in_flight? && updated_at.present? && updated_at < STALE_AFTER.ago
  end

  # The user message this turn answers
  def prompt
    chat.messages
      .where(type: "UserMessage")
      .where("created_at < ?", created_at)
      .ordered
      .last
  end

  def append_text!(text)
    self.content += text
    save!
  end

  def respond_later
    AssistantResponseJob.perform_later(self)
  end

  # Runs the turn. The claim (pending → streaming under a row lock) makes a re-run of the job a no-op, so a
  # Sidekiq retry or a duplicate job never calls the LLM or the tool functions twice.
  def generate_response
    return unless claim

    raise AiDisabledError, "AI is disabled for this user" unless chat.user.ai_enabled?

    chat.assistant.respond_to(self)
  rescue => e
    fail_turn(e)
  end

  # Fails the turn unless it already ended (for example, the reaper failed it while the job was still running)
  def fail_turn(error)
    fail!(error)
  rescue AASM::InvalidTransition
    Rails.logger.warn("AssistantMessage #{id} is #{status}; not failing it again (#{error.message})")
  end

  private
    def blank_content_allowed?
      !complete?
    end

    def claim
      start!
      true
    rescue AASM::InvalidTransition
      Rails.logger.info("AssistantMessage #{id} is #{status}, not pending; skipping the response job")
      false
    end

    # The provider conversation pointer moves only when a turn completes, so a failed or abandoned turn never
    # leaves the chat pointing at a response with unresolved function calls.
    def move_response_pointer(provider_response_id = nil)
      self.provider_id = provider_response_id
      chat.update!(
        latest_assistant_response_id: provider_response_id.presence || chat.latest_assistant_response_id,
        error: nil
      )
    end

    def record_error(error = nil)
      chat.update!(error: error&.to_json)
    end

    def reset_attempt
      self.content = ""
      self.provider_id = nil
      tool_calls.destroy_all
      chat.update!(error: nil)
    end
end
