class Chat < ApplicationRecord
  include Debuggable

  # Only one turn (prompt + assistant response) runs per chat at a time
  TurnInProgressError = Class.new(StandardError)
  NothingToRetryError = Class.new(StandardError)

  belongs_to :user

  has_one :viewer, class_name: "User", foreign_key: :last_viewed_chat_id, dependent: :nullify # "Last chat user has viewed"
  has_many :messages, dependent: :destroy
  has_many :assistant_messages

  validates :title, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  class << self
    def start!(prompt, model:, title: nil)
      # Ensure we have a valid model by using the default if none provided
      effective_model = model.presence || default_model

      chat = nil
      turn = transaction do
        chat = create!(title: title.presence || generate_title(prompt))
        chat.create_turn!(prompt, ai_model: effective_model)
      end

      turn.respond_later
      chat
    end

    def generate_title(prompt)
      prompt.first(80)
    end

    # Returns the default AI model to use for chats
    # Priority: ENV variable > Setting > OpenAI default
    def default_model
      ENV["OPENAI_MODEL"].presence || Setting.openai_model.presence || Provider::Openai::DEFAULT_MODEL
    end
  end

  # Starts a turn: saves the prompt and a pending assistant message, then queues the response job.
  # Raises TurnInProgressError while another turn of this chat is running.
  def ask!(content, ai_model: nil)
    turn = with_lock do
      fail_stale_turns
      raise TurnInProgressError if turn_in_flight?

      create_turn!(content, ai_model: ai_model.presence || self.class.default_model)
    end

    turn.respond_later
    turn
  end

  # Use ask! (it takes the chat lock); this is only for a chat created in the same transaction.
  def create_turn!(content, ai_model:)
    UserMessage.create!(chat: self, content: content, ai_model: ai_model)
    update!(error: nil) if error.present?
    AssistantMessage.create!(chat: self, ai_model: ai_model)
  end

  # Retries the last turn: a failed one, a lost one (in flight for longer than AssistantMessage::STALE_AFTER),
  # or a prompt that never got an assistant message (the previous version left those when its job was lost).
  # Raises TurnInProgressError while a turn runs and NothingToRetryError when the last turn completed.
  def retry_last_turn!
    turn = with_lock do
      fail_stale_turns
      raise TurnInProgressError if turn_in_flight?

      last = last_turn_message

      if last.is_a?(AssistantMessage) && last.failed?
        last.requeue!
        last
      elsif last.is_a?(UserMessage)
        AssistantMessage.create!(chat: self, ai_model: last.ai_model)
      else
        raise NothingToRetryError
      end
    end

    turn.respond_later
    turn
  end

  # A job queued by the previous version carries the user message instead of an assistant message.
  # Returns the new pending turn, or nil when the prompt was answered or another turn runs.
  def adopt_unanswered_prompt(user_message)
    with_lock do
      next nil if turn_in_flight? || last_turn_message != user_message

      AssistantMessage.create!(chat: self, ai_model: user_message.ai_model)
    end
  end

  def in_flight_turn
    assistant_messages.in_flight.ordered.last
  end

  def turn_in_flight?
    in_flight_turn.present?
  end

  def retryable?
    last = last_turn_message

    case last
    when AssistantMessage then last.failed? || last.stale?
    when UserMessage then true
    else false
    end
  end

  # The last message is a prompt with no assistant message after it
  def unanswered_prompt?
    last_turn_message.is_a?(UserMessage)
  end

  def assistant
    @assistant ||= Assistant.for_chat(self)
  end

  def conversation_messages
    if debug_mode?
      messages
    else
      messages.where(type: [ "UserMessage", "AssistantMessage" ])
    end
  end

  private
    def last_turn_message
      messages.where(type: [ "UserMessage", "AssistantMessage" ]).ordered.last
    end

    def fail_stale_turns
      assistant_messages.stale.each do |turn|
        turn.fail_turn(AssistantMessage::StaleTurnError.new("No progress for #{AssistantMessage::STALE_AFTER.inspect}"))
      end
    end
end
