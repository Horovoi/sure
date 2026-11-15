require "test_helper"

class ScheduledJobs::StatusTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 11, 16, 12, 0) # a Monday
    Setting.stubs(:auto_sync_enabled?).returns(false)
    Sidekiq::ProcessSet.stubs(:new).returns([ { "beat" => (@now - 5.seconds).to_f } ])
  end

  test "a job that ran at its last due time is ok, with its next run" do
    stub_cron_jobs(cron_job("sync_hourly", "0 * * * *", last: Time.utc(2026, 11, 16, 12, 0)))

    entry = entry_named("sync_hourly")

    assert_equal :ok, entry.state
    assert_equal Time.utc(2026, 11, 16, 12, 0), entry.last_run_at
    assert_equal Time.utc(2026, 11, 16, 13, 0), entry.next_run_at
    assert_not entry.problem?
  end

  test "a job whose due run is more than an hour late is overdue" do
    stub_cron_jobs(cron_job("full_backup", "0 4 * * * Europe/Kyiv", last: Time.utc(2026, 11, 14, 2, 0)))

    assert_equal :overdue, entry_named("full_backup").state
  end

  test "a run that is due less than an hour ago is not overdue yet" do
    now = Time.utc(2026, 11, 16, 2, 30) # 04:30 Kyiv, the 04:00 run is 30 minutes late
    stub_cron_jobs(cron_job("full_backup", "0 4 * * * Europe/Kyiv", last: Time.utc(2026, 11, 15, 2, 0)))

    assert_equal :ok, ScheduledJobs::Status.new(now: now).entries.find { |e| e.name == "full_backup" }.state
  end

  test "a weekday job is not overdue on Monday morning" do
    now = Time.utc(2026, 11, 16, 9, 0) # Monday; the last run was Friday 22:00 UTC
    stub_cron_jobs(cron_job("import_market_data", "0 22 * * 1-5", last: Time.utc(2026, 11, 13, 22, 0)))

    assert_equal :ok, ScheduledJobs::Status.new(now: now).entries.find { |e| e.name == "import_market_data" }.state
  end

  test "a job that never ran is not overdue" do
    stub_cron_jobs(cron_job("sync_hourly", "0 * * * *", last: nil))

    entry = entry_named("sync_hourly")
    assert_equal :ok, entry.state
    assert_nil entry.last_run_at
  end

  test "an expected job that Redis does not have is not scheduled" do
    stub_cron_jobs

    status = ScheduledJobs::Status.new(now: @now)
    names = status.entries.map(&:name)

    %w[sync_hourly reap_stale_work full_backup clean_data run_security_health_checks generate_subscription_transactions].each do |name|
      assert_includes names, name
      assert_equal :not_scheduled, status.entries.find { |e| e.name == name }.state
    end
    assert_not_includes names, AutoSyncScheduler::JOB_NAME
  end

  test "the auto sync job is expected only while auto sync is on" do
    Setting.stubs(:auto_sync_enabled?).returns(true)
    stub_cron_jobs

    assert_equal :not_scheduled, entry_named(AutoSyncScheduler::JOB_NAME).state
  end

  test "a job that Redis has but the code does not expect is still listed" do
    stub_cron_jobs(cron_job("left_over", "0 1 * * *", last: Time.utc(2026, 11, 16, 1, 0)))

    assert_equal :ok, entry_named("left_over").state
  end

  test "a disabled job is disabled, without a next run" do
    stub_cron_jobs(cron_job("sync_hourly", "0 * * * *", last: Time.utc(2026, 11, 10, 0, 0), status: "disabled"))

    entry = entry_named("sync_hourly")
    assert_equal :disabled, entry.state
    assert_nil entry.next_run_at
  end

  test "problems are listed first" do
    stub_cron_jobs(cron_job("sync_hourly", "0 * * * *", last: Time.utc(2026, 11, 16, 12, 0)))

    states = ScheduledJobs::Status.new(now: @now).entries.map(&:state)
    assert_equal states.sort_by { |state| ScheduledJobs::Status::STATE_ORDER.fetch(state) }, states
    assert_equal :ok, states.last
  end

  test "the worker is alive when a process beat in the last minute" do
    stub_cron_jobs

    assert ScheduledJobs::Status.new(now: @now).worker_alive?
  end

  test "the worker is down when no process beat in the last minute" do
    stub_cron_jobs
    Sidekiq::ProcessSet.stubs(:new).returns([ { "beat" => (@now - 5.minutes).to_f } ])

    assert_not ScheduledJobs::Status.new(now: @now).worker_alive?
  end

  test "the worker is down when there is no process" do
    stub_cron_jobs
    Sidekiq::ProcessSet.stubs(:new).returns([])

    assert_not ScheduledJobs::Status.new(now: @now).worker_alive?
  end

  test "a Redis error makes the status unavailable instead of raising" do
    Sidekiq::Cron::Job.stubs(:all).raises(RedisClient::CannotConnectError, "connection refused")

    status = ScheduledJobs::Status.new(now: @now)

    assert_not status.available?
    assert_empty status.entries
    assert_not status.worker_alive?
  end

  private
    def stub_cron_jobs(*jobs)
      Sidekiq::Cron::Job.stubs(:all).returns(jobs)
    end

    def cron_job(name, cron, last:, status: "enabled")
      stub(name: name, cron: cron, last_enqueue_time: last, enabled?: status == "enabled")
    end

    def entry_named(name)
      ScheduledJobs::Status.new(now: @now).entries.find { |entry| entry.name == name } || flunk("no entry for #{name}")
    end
end
