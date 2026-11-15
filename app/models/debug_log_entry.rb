# frozen_string_literal: true

# An operational event worth a look later: a failed sync, work the stale work reaper had
# to finish, a failed AI rule run. Only super admins see the log (Settings > Debug), and
# DebugLogCleanupJob deletes entries after config.x.debug_log.retention_days.
#
# Not an audit log: rows expire, and no LLM prompt or response is stored here.
class DebugLogEntry < ApplicationRecord
  LEVELS = %w[debug info warn error].freeze
  MESSAGE_LIMIT = 10_000

  belongs_to :family, optional: true
  belongs_to :account, optional: true
  belongs_to :user, optional: true

  validates :category, :level, :message, :source, presence: true
  validates :level, inclusion: { in: LEVELS }

  scope :recent, -> { order(created_at: :desc) }
  scope :with_category, ->(category) { category.present? ? where(category: category) : all }
  scope :with_level, ->(level) { level.present? ? where(level: level) : all }
  scope :with_source, ->(source) { source.present? ? where(source: source) : all }
  scope :with_provider_key, ->(provider_key) { provider_key.present? ? where(provider_key: provider_key) : all }

  class << self
    # Writes an entry and raises on failure. The family is taken from the account or the
    # user when it is not given. Metadata keys that look secret (config.filter_parameters)
    # are filtered, and the message is cut to MESSAGE_LIMIT characters.
    def log!(category:, level:, message:, source:, metadata: {}, family: nil, family_id: nil,
             account: nil, account_id: nil, user: nil, user_id: nil, provider_key: nil, provider: nil)
      account = account || find_record(Account, account_id)
      user = user || find_record(User, user_id)
      family = family || find_record(Family, family_id) || account&.family || user&.family

      # A savepoint, so a failed insert never aborts the caller's transaction
      transaction(requires_new: true) do
        create!(
          category: category.to_s,
          level: level.to_s,
          message: message.to_s.truncate(MESSAGE_LIMIT),
          source: source.to_s,
          metadata: normalize_metadata(metadata),
          family: family,
          account: account,
          user: user,
          provider_key: normalize_provider_key(provider_key, provider)
        )
      end
    end

    # Same as log!, but never raises: logging a failure must not cause another one.
    # Returns the entry, or nil when it could not be written.
    def capture(...)
      log!(...)
    rescue => e
      begin
        Rails.logger.error("DebugLogEntry.capture failed: #{e.class}: #{e.message}")
      rescue
        nil
      end
      nil
    end

    private
      def normalize_metadata(metadata)
        return {} if metadata.blank?

        hash = metadata.respond_to?(:to_h) && !metadata.is_a?(String) ? metadata.to_h : { value: metadata.to_s }
        metadata_filter.filter(hash.deep_stringify_keys)
      end

      def metadata_filter
        ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      end

      def normalize_provider_key(provider_key, provider)
        return provider_key.to_s if provider_key.present?
        return if provider.blank?

        provider_name = provider.is_a?(String) || provider.is_a?(Symbol) ? provider.to_s : provider.class.name.demodulize
        provider_name.underscore
      end

      def find_record(klass, id)
        return if id.blank?

        klass.find_by(id: id)
      end
  end
end
