# Tells a model whether Active Record encryption has keys, so it can guard its
# `encrypts` declarations with `if encryption_ready?`.
#
# The keys can come from three places, and all of them end up in
# Rails.application.config.active_record.encryption before the models load:
#   - Rails credentials (config/application.rb copies them in),
#   - the ACTIVE_RECORD_ENCRYPTION_* environment variables, or
#   - the keys config/initializers/active_record_encryption.rb derives from
#     SECRET_KEY_BASE on a self-hosted install that sets neither.
#
# The old per-model check looked only at credentials and the environment
# variables, so the derived keys (the default self-hosted setup, and the one
# production uses) never counted and provider credentials were stored in
# plain text.
module Encryptable
  extend ActiveSupport::Concern

  KEY_NAMES = %i[primary_key deterministic_key key_derivation_salt].freeze

  class << self
    def ready?(config: Rails.application.config.active_record.encryption,
               credentials: Rails.application.credentials.active_record_encryption)
      keys_present?(config) || keys_present?(credentials)
    end

    def keys_present?(source)
      return false if source.blank?

      KEY_NAMES.all? { |name| source[name].present? }
    rescue NoMethodError, TypeError
      false
    end
  end

  class_methods do
    def encryption_ready?
      Encryptable.ready?
    end
  end
end
