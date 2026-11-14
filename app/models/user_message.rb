class UserMessage < Message
  validates :ai_model, presence: true

  def role
    "user"
  end

  # The assistant message that answers this prompt: the next assistant message in the chat
  def reply
    chat.messages
      .where(type: "AssistantMessage")
      .where("created_at > ?", created_at)
      .ordered
      .first
  end
end
