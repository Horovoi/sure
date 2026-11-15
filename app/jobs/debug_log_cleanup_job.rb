# frozen_string_literal: true

# Deletes debug log entries older than config.x.debug_log.retention_days
# (DEBUG_LOG_RETENTION_DAYS, 90 by default). Scheduled daily (config/schedule.yml).
class DebugLogCleanupJob < ApplicationJob
  queue_as :scheduled

  def perform
    deleted_count = DebugLogEntry.where(created_at: ...retention_period.ago).delete_all
    Rails.logger.info("DebugLogCleanupJob: deleted #{deleted_count} debug log entries older than #{retention_period.inspect}") if deleted_count.positive?
    deleted_count
  end

  private
    def retention_period
      Rails.application.config.x.debug_log.retention_days.days
    end
end
