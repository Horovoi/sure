class AssistantResponseJob < ApplicationJob
  queue_as :high_priority

  # Never raises for a failed turn: the turn records its own failure, and a Sidekiq retry would run it again.
  def perform(message)
    turn = case message
    when AssistantMessage then message
    # Jobs queued by the previous version carry the user message
    when UserMessage then message.chat.adopt_unanswered_prompt(message)
    end

    turn&.generate_response
  end

  private
    # The assistant's "today" and its default date ranges follow the user's family
    def family_for_time_zone
      arguments.first.chat.user.family
    rescue StandardError
      nil
    end
end
