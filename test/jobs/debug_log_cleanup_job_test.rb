require "test_helper"

class DebugLogCleanupJobTest < ActiveJob::TestCase
  setup do
    @original_retention_days = Rails.application.config.x.debug_log.retention_days
    Rails.application.config.x.debug_log.retention_days = 90
  end

  teardown do
    Rails.application.config.x.debug_log.retention_days = @original_retention_days
  end

  test "deletes entries older than 90 days and keeps newer ones" do
    travel_to Time.zone.parse("2026-11-15 12:00:00") do
      old_entry = create_entry(91.days.ago)
      boundary_entry = create_entry(90.days.ago)
      recent_entry = create_entry(Time.current)

      assert_difference "DebugLogEntry.count", -1 do
        DebugLogCleanupJob.perform_now
      end

      assert_not DebugLogEntry.exists?(old_entry.id)
      assert DebugLogEntry.exists?(boundary_entry.id)
      assert DebugLogEntry.exists?(recent_entry.id)
    end
  end

  test "uses the configured retention" do
    Rails.application.config.x.debug_log.retention_days = 30

    travel_to Time.zone.parse("2026-11-15 12:00:00") do
      old_entry = create_entry(31.days.ago)
      boundary_entry = create_entry(30.days.ago)

      assert_difference "DebugLogEntry.count", -1 do
        DebugLogCleanupJob.perform_now
      end

      assert_not DebugLogEntry.exists?(old_entry.id)
      assert DebugLogEntry.exists?(boundary_entry.id)
    end
  end

  test "is scheduled daily on the scheduled queue" do
    entry = YAML.load_file(Rails.root.join("config/schedule.yml"))["clean_debug_log_entries"]

    assert_equal "DebugLogCleanupJob", entry["class"]
    assert_equal "scheduled", entry["queue"]
  end

  private
    def create_entry(at)
      DebugLogEntry.create!(category: "test", level: "info", message: "entry", source: "Test", created_at: at, updated_at: at)
    end
end
