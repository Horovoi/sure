require "test_helper"

class AutoSyncSchedulerTest < ActiveSupport::TestCase
  setup do
    Setting.auto_sync_enabled = true
    Setting.auto_sync_time = "02:22"
    Setting.auto_sync_timezone = "Europe/Helsinki"
  end

  teardown { AutoSyncScheduler.remove_job }

  test "creates the nightly sync in the configured local time and zone" do
    AutoSyncScheduler.sync!

    job = Sidekiq::Cron::Job.find(AutoSyncScheduler::JOB_NAME)
    assert_equal "22 2 * * * Europe/Helsinki", job.cron
    assert_equal "SyncAllJob", job.klass
  end

  test "registers the nightly sync as an ActiveJob" do
    AutoSyncScheduler.sync!

    assert_equal "1", Sidekiq::Cron::Job.find(AutoSyncScheduler::JOB_NAME).to_hash[:active_job]
  end

  test "removes the job when auto sync is disabled" do
    AutoSyncScheduler.sync!
    Setting.auto_sync_enabled = false

    AutoSyncScheduler.sync!

    assert_nil Sidekiq::Cron::Job.find(AutoSyncScheduler::JOB_NAME)
  end

  test "schedule.yml no longer defines the jobs owned by Settings" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    ScheduledJobsManager::CONFIGURABLE_JOBS.each_value do |config|
      assert_not schedule.key?(config[:cron_name]), "#{config[:cron_name]} must not be in schedule.yml"
    end
    assert_not schedule.key?(AutoSyncScheduler::JOB_NAME)
  end
end
