require "test_helper"

class FullBackupJobTest < ActiveJob::TestCase
  test "writes the daily bundle" do
    Backup::Bundle.expects(:create!).with(kind: :daily).returns(Pathname("/backups/bundles/daily/x"))

    with_env_overrides("STAGING_CLONE" => nil) do
      FullBackupJob.perform_now
    end
  end

  test "does nothing on the staging copy" do
    Backup::Bundle.expects(:create!).never

    with_env_overrides("STAGING_CLONE" => "1") do
      FullBackupJob.perform_now
    end
  end

  test "runs on the scheduled queue" do
    assert_equal "scheduled", FullBackupJob.new.queue_name
  end

  test "is scheduled daily at 04:00 Kyiv time as an Active Job" do
    entry = YAML.load_file(Rails.root.join("config", "schedule.yml")).fetch("full_backup")

    assert_equal "0 4 * * * Europe/Kyiv", entry["cron"]
    assert_equal "FullBackupJob", entry["class"]
    assert_equal "scheduled", entry["queue"]
    assert_equal true, entry["active_job"]
  end
end
