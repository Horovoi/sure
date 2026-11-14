require "test_helper"

class CronJobWriterTest < ActiveSupport::TestCase
  # Unique per test: parallel workers share one Redis
  setup { @job = "cron_job_writer_test_#{SecureRandom.hex(6)}" }
  teardown { CronJobWriter.remove(@job) }

  test "daily_cron carries the IANA zone so the job follows daylight-saving time" do
    assert_equal "5 0 * * * Europe/Helsinki", CronJobWriter.daily_cron("00:05", "Helsinki")
    assert_equal "15 3 * * 1-5 Etc/UTC", CronJobWriter.daily_cron("03:15", "UTC", days: "1-5")
  end

  test "daily_cron falls back to UTC and 03:00 for bad input" do
    assert_equal "0 3 * * * Etc/UTC", CronJobWriter.daily_cron("nonsense", "Not/AZone")
  end

  test "upsert keeps an unchanged job and its enqueue history" do
    CronJobWriter.upsert(name: @job, klass: "SyncAllJob", cron: "5 0 * * * Europe/Helsinki", description: "test")
    job = Sidekiq::Cron::Job.find(@job)
    job.send(:instance_variable_set, :@last_enqueue_time, Time.utc(2026, 1, 1, 0, 0))
    job.send(:save_last_enqueue_time)

    CronJobWriter.upsert(name: @job, klass: "SyncAllJob", cron: "5 0 * * * Europe/Helsinki", description: "test")

    assert_equal Time.utc(2026, 1, 1, 0, 0).to_i, Sidekiq::Cron::Job.find(@job).last_enqueue_time.to_i
  end

  test "upsert replaces a changed job" do
    CronJobWriter.upsert(name: @job, klass: "SyncAllJob", cron: "5 0 * * * Europe/Helsinki", description: "test")
    CronJobWriter.upsert(name: @job, klass: "SyncAllJob", cron: "10 1 * * * Europe/Helsinki", description: "test")

    assert_equal "10 1 * * * Europe/Helsinki", Sidekiq::Cron::Job.find(@job).cron
    assert_equal "dynamic", Sidekiq::Cron::Job.find(@job).source
  end

  test "upsert raises on an invalid job instead of reporting success" do
    assert_raises(CronJobWriter::Error) do
      CronJobWriter.upsert(name: @job, klass: "SyncAllJob", cron: "not a cron", description: "test")
    end
  end
end
