# The per-turn /mcp bearer of the in-app Claude chat. Assistant::Claude mints one for each turn and hands it to the
# bridge, which gives it to Claude Code for Sure's MCP server; the bridge never holds a long-lived Sure secret.
#
# The token is signed (Rails.application.message_verifier(:mcp_turn)) and names the user, the assistant message it
# answers and the tool scope. It expires after 15 minutes, and McpController accepts it only while that message is
# still streaming and its user has the AI switch on, so it dies with the turn. The scope is always :full: the chat
# gets every tool with no approval prompt (owner answer 2), and every call is audited under claude_chat.
class Mcp::TurnToken
  PURPOSE = :mcp_turn
  EXPIRES_IN = 15.minutes
  SCOPE = :full

  class << self
    def generate(assistant_message, scope: SCOPE)
      verifier.generate(
        { "user_id" => assistant_message.chat.user_id, "assistant_message_id" => assistant_message.id, "scope" => scope.to_s },
        expires_in: EXPIRES_IN,
        purpose: PURPOSE
      )
    end

    # The credential for a valid token, or nil when the token is forged, expired, for a turn that is not streaming,
    # for a message of another user, or for a user who is gone.
    def credential_for(token, client_name: nil)
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return unless payload.is_a?(Hash)

      payload = payload.stringify_keys
      scope = payload["scope"].to_s.to_sym
      return unless Mcp::Credential::SCOPES.include?(scope)

      user = User.find_by(id: payload["user_id"])
      return unless user&.active?

      assistant_message = AssistantMessage.joins(:chat).find_by(id: payload["assistant_message_id"], chats: { user_id: user.id })
      return unless assistant_message&.streaming?

      Mcp::Credential.new(user: user, kind: :turn, scope: scope, assistant_message: assistant_message, client_name: client_name)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    # A signed token has a "--" between its data and its digest; the static MCP_API_TOKEN is plain hex
    def token_format?(token)
      token.to_s.include?("--")
    end

    private
      def verifier
        Rails.application.message_verifier(PURPOSE)
      end
  end
end
