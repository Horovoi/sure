class AutoSyncScheduler
  JOB_NAME = "sync_all_accounts"

  # Reconciles the nightly family sync with the settings. Runs at every Sidekiq start
  # (config/initializers/sidekiq.rb) and whenever the hosting settings change.
  def self.sync!
    Rails.logger.info("[AutoSyncScheduler] auto_sync_enabled=#{Setting.auto_sync_enabled}, time=#{Setting.auto_sync_time}")
    if Setting.auto_sync_enabled?
      upsert_job
    else
      remove_job
    end
  end

  def self.upsert_job
    time_str = Setting.auto_sync_time || "02:22"

    unless Setting.valid_auto_sync_time?(time_str)
      Rails.logger.error("[AutoSyncScheduler] Invalid time format: #{time_str}, using default 02:22")
      time_str = "02:22"
    end

    CronJobWriter.upsert(
      name: JOB_NAME,
      klass: "SyncAllJob",
      cron: CronJobWriter.daily_cron(time_str, Setting.auto_sync_timezone.presence || "UTC"),
      description: "Syncs all accounts for all families"
    )
  end

  def self.remove_job
    CronJobWriter.remove(JOB_NAME)
  end
end
