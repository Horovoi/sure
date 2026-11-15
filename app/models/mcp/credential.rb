# Who is calling /mcp, as established by McpController's authentication. It names the user the tools run as, the
# tool scope, and what the tool-call audit records (which channel, which chat message).
#
# Kinds:
# - :static, the MCP_API_TOKEN bearer used by Claude Code. No assistant message.
# - :turn, the per-turn token the in-app Claude chat gets (added with the Claude chat adapter), tied to the
#   assistant message being answered.
#
# Scope (Assistant.function_classes_for): both kinds get :full, every tool with no approval prompt (owner answer
# 2). :read lists and runs only the read tools; it exists for tests and a future read-only token.
class Mcp::Credential
  KINDS = %i[static turn].freeze
  SCOPES = Assistant::TOOL_SCOPES

  attr_reader :user, :kind, :scope, :assistant_message, :client_name

  def self.static(user, client_name: nil)
    new(user: user, kind: :static, scope: :full, client_name: client_name)
  end

  def self.turn(user, assistant_message:, client_name: nil)
    new(user: user, kind: :turn, scope: :full, assistant_message: assistant_message, client_name: client_name)
  end

  def initialize(user:, kind:, scope: :full, assistant_message: nil, client_name: nil)
    raise ArgumentError, "Unknown MCP credential kind: #{kind.inspect}" unless KINDS.include?(kind)
    raise ArgumentError, "Unknown MCP credential scope: #{scope.inspect}" unless SCOPES.include?(scope)
    raise ArgumentError, "An MCP credential needs a user" if user.nil?

    @user = user
    @kind = kind
    @scope = scope
    @assistant_message = assistant_message
    @client_name = client_name
  end

  def function_classes
    Assistant.function_classes_for(scope)
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
