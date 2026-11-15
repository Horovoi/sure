# The daily full backup (config/schedule.yml, 04:00 Kyiv): database, uploaded files,
# cached icons and the encrypted .env.production, mirrored off-site. See Backup::Bundle.
#
# Off on the staging copy: it would only back up the copy. Manual and pre-reset
# bundles still run there and land in backups/staging.
class FullBackupJob < ApplicationJob
  queue_as :scheduled

  def perform
    if ENV["STAGING_CLONE"] == "1"
      Rails.logger.info("[FullBackupJob] skipped on the staging copy")
      return
    end

    dir = Backup::Bundle.create!(kind: :daily)
    Rails.logger.info("[FullBackupJob] wrote #{dir}")
  end
end
