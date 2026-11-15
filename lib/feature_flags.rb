# frozen_string_literal: true

# Feature switches read from the environment. Each one is fixed for the life of
# the process: change the variable and restart to flip it.
module FeatureFlags
  class << self
    # Where SSO provider settings come from: "db" (managed on the admin SSO
    # providers page) or "yaml" (config/auth.yml). AUTH_PROVIDERS_SOURCE wins
    # when set. Unset, a self-hosted instance uses the database, a managed one
    # uses YAML, and the test environment uses YAML so the suite does not depend
    # on the SELF_HOSTED setting of the shell that runs it.
    def db_sso_providers?
      auth_source = ENV["AUTH_PROVIDERS_SOURCE"].to_s.strip.downcase
      return auth_source == "db" if auth_source.present?
      return false if Rails.env.test?

      Rails.configuration.app_mode.self_hosted?
    end
  end
end
