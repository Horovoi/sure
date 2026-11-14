class Session < ApplicationRecord
  belongs_to :user
  # Only an approved session within its TTL counts; a completed, rejected or
  # expired one is ignored even if the link was not cleared yet.
  belongs_to :active_impersonator_session,
    -> { active },
    class_name: "ImpersonationSession",
    optional: true

  before_create do
    self.user_agent = Current.user_agent
    self.ip_address = Current.ip_address
  end

  # An unsaved session for one API or MCP request, which authenticate without a browser
  # session. Built with new rather than user.sessions.build, so saving the user can never
  # persist it. Never reuse a browser session instead: it may be impersonating someone,
  # which would change Current.user.
  def self.ephemeral_for(user, request)
    new(user: user, user_agent: request.user_agent, ip_address: request.ip)
  end

  def get_preferred_tab(tab_key)
    data.dig("tab_preferences", tab_key)
  end

  def set_preferred_tab(tab_key, tab_value)
    data["tab_preferences"] ||= {}
    data["tab_preferences"][tab_key] = tab_value
    save!
  end
end
