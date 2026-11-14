module Assistant::Broadcastable
  extend ActiveSupport::Concern

  private
    # The pending assistant message renders the indicator; this only changes its text while the turn runs
    def update_thinking(thought)
      chat.broadcast_replace target: "thinking-indicator", partial: "chats/thinking_indicator", locals: { chat: chat, message: thought }
    end
end
