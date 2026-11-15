# Who is calling /mcp, as established by McpController's authentication. Every client gets every tool (owner
# answer 14), so the credential filters nothing: it names the user the tools run as and feeds the tool-call
# audit (which channel, which chat message).
#
# Kinds:
# - :static, the MCP_API_TOKEN bearer used by Claude Code. No assistant message.
# - :turn, the per-turn token the in-app Claude chat gets (added with the Claude chat adapter), tied to the
#   assistant message being answered.
class Mcp::Credential
  KINDS = %i[static turn].freeze

  attr_reader :user, :kind, :assistant_message, :client_name

  def self.static(user, client_name: nil)
    new(user: user, kind: :static, client_name: client_name)
  end

  def initialize(user:, kind:, assistant_message: nil, client_name: nil)
    raise ArgumentError, "Unknown MCP credential kind: #{kind.inspect}" unless KINDS.include?(kind)
    raise ArgumentError, "An MCP credential needs a user" if user.nil?

    @user = user
    @kind = kind
    @assistant_message = assistant_message
    @client_name = client_name
  end

  # Every credential sees the full tool set. Kept as a value so the tool registry and the audit can read it.
  def scope
    :full
  end

  def family
    user.family
  end

  def static?
    kind == :static
  end

  def turn?
    kind == :turn
  end
end
