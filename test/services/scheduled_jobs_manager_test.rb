require "test_helper"

class ScheduledJobsManagerTest < ActiveSupport::TestCase
  setup do
    # Reset to defaults before each test
    Setting.scheduled_jobs_start_time = "03:00"
    Setting.scheduled_jobs_timezone = nil
    Setting.data_cleaner_time = nil
    Setting.security_health_check_time = nil
    Setting.subscription_transactions_time = nil
  end

  test "effective_time_for returns default staggered times" do
    assert_equal "03:00", ScheduledJobsManager.effective_time_for(:data_cleaner)
    assert_equal "03:15", ScheduledJobsManager.effective_time_for(:security_health_check)
    assert_equal "03:30", ScheduledJobsManager.effective_time_for(:subscription_transactions)
  end

  test "effective_time_for uses start_time offset" do
    Setting.scheduled_jobs_start_time = "05:00"

    assert_equal "05:00", ScheduledJobsManager.effective_time_for(:data_cleaner)
    assert_equal "05:15", ScheduledJobsManager.effective_time_for(:security_health_check)
    assert_equal "05:30", ScheduledJobsManager.effective_time_for(:subscription_transactions)
  end

  test "effective_time_for handles time wrapping past midnight" do
    Setting.scheduled_jobs_start_time = "23:50"

    assert_equal "23:50", ScheduledJobsManager.effective_time_for(:data_cleaner)
    assert_equal "00:05", ScheduledJobsManager.effective_time_for(:security_health_check)
    assert_equal "00:20", ScheduledJobsManager.effective_time_for(:subscription_transactions)
  end

  test "effective_time_for returns custom time when set" do
    Setting.data_cleaner_time = "06:00"

    assert_equal "06:00", ScheduledJobsManager.effective_time_for(:data_cleaner)
    assert_equal "03:15", ScheduledJobsManager.effective_time_for(:security_health_check)
  end

  test "effective_times returns all job times" do
    times = ScheduledJobsManager.effective_times

    assert_equal({ data_cleaner: "03:00", security_health_check: "03:15", subscription_transactions: "03:30" }, times)
  end

  test "timezone returns UTC by default" do
    assert_equal "UTC", ScheduledJobsManager.timezone
  end

  test "timezone returns configured timezone" do
    Setting.scheduled_jobs_timezone = "America/New_York"
    assert_equal "America/New_York", ScheduledJobsManager.timezone
  end

  test "has_custom_times? returns false when no custom times set" do
    assert_not ScheduledJobsManager.has_custom_times?
  end

  test "has_custom_times? returns true when any custom time is set" do
    Setting.security_health_check_time = "04:00"
    assert ScheduledJobsManager.has_custom_times?
  end

  test "reset_custom_times! clears all custom times" do
    Setting.data_cleaner_time = "05:00"
    Setting.security_health_check_time = "06:00"
    Setting.subscription_transactions_time = "07:00"

    ScheduledJobsManager.reset_custom_times!

    assert_nil Setting.data_cleaner_time
    assert_nil Setting.security_health_check_time
    assert_nil Setting.subscription_transactions_time
  end

  test "CONFIGURABLE_JOBS contains expected jobs" do
    assert_includes ScheduledJobsManager::CONFIGURABLE_JOBS.keys, :data_cleaner
    assert_includes ScheduledJobsManager::CONFIGURABLE_JOBS.keys, :security_health_check
    assert_includes ScheduledJobsManager::CONFIGURABLE_JOBS.keys, :subscription_transactions
  end
end
