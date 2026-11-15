class Session < ApplicationRecord
  # The tab preferences a browser may store, by key, with the values each one
  # accepts. DS::Tabs posts its session_key and the clicked tab id to
  # CurrentSessionsController, so anything else is ignored rather than written
  # into the session row.
  ALLOWED_TABS = {
    "account_sidebar_tab" => %w[asset liability all].freeze
  }.freeze

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

  def self.allowed_tab?(tab_key, tab_value)
    ALLOWED_TABS.fetch(tab_key.to_s, []).include?(tab_value.to_s)
  end

  # Returns the stored value only while it is still an allowed one, so a value
  # stored before the list changed falls back to the caller's default.
  def get_preferred_tab(tab_key)
    value = data.dig("tab_preferences", tab_key.to_s)
    value if self.class.allowed_tab?(tab_key, value)
  end

  # Stores the preference and returns true, or ignores an unknown key or value
  # and returns false.
  def set_preferred_tab(tab_key, tab_value)
    return false unless self.class.allowed_tab?(tab_key, tab_value)

    self.data = (data || {}).merge(
      "tab_preferences" => (data&.dig("tab_preferences") || {}).merge(tab_key.to_s => tab_value.to_s)
    )
    save!
  end
end
