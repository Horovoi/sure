class AssistantResponseJob < ApplicationJob
  queue_as :high_priority

  # The chat (and its messages) was deleted while the job waited
  discard_on ActiveJob::DeserializationError

  # Never raises for a failed turn: the turn records its own failure, and a Sidekiq retry would run it again.
  def perform(message)
    turn = case message
    when AssistantMessage then message
    # Jobs queued by the previous version carry the user message
    when UserMessage then message.chat.adopt_unanswered_prompt(message)
    end

    turn&.generate_response
  end
end
