require "test_helper"

# When the process firing a cron tick could not resolve the job class (for example
# another code version polling the same Redis), sidekiq-cron pushed a raw
# Sidekiq::Job payload and the worker crashed with "undefined method jid=", because
# every scheduled class is an Active Job. active_job: true on every entry prevents that.
class CronScheduleTest < ActiveSupport::TestCase
  SCHEDULE = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))
  JOB_WRAPPER = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"

  test "every scheduled job is an ActiveJob flagged with active_job: true on the scheduled queue" do
    SCHEDULE.each do |name, config|
      assert config["class"].constantize < ApplicationJob, "#{name}: #{config["class"]} must be an ApplicationJob"
      assert_equal true, config["active_job"], "#{name}: set `active_job: true` so sidekiq-cron always enqueues an ActiveJob payload"
      assert_equal "scheduled", config["queue"], "#{name}: cron entries run on the scheduled queue"
    end
  end

  test "every job written from Settings is an ApplicationJob" do
    classes = ScheduledJobsManager::CONFIGURABLE_JOBS.values.map { |config| config[:class] } + [ "SyncAllJob" ]

    classes.each do |klass|
      assert klass.constantize < ApplicationJob, "#{klass} must be an ApplicationJob"
    end
  end

  test "cron ticks enqueue an ActiveJob wrapper even when the job class can't be resolved" do
    Sidekiq::Cron::Support.stubs(:safe_constantize).returns(nil)
    Sidekiq::Cron::Job.any_instance.stubs(:save_last_enqueue_time)
    Sidekiq::Cron::Job.any_instance.stubs(:add_jid_history)

    SCHEDULE.each do |name, config|
      job = Sidekiq::Cron::Job.new(config.merge("name" => name, "status" => "enabled", "last_enqueue_time" => Time.current.to_s))

      Sidekiq::Client.expects(:push).with do |payload|
        payload["class"] == JOB_WRAPPER &&
          payload["wrapped"] == config["class"] &&
          payload["queue"] == config["queue"] &&
          payload["args"].first["job_class"] == config["class"]
      end.returns("jid")

      job.enqueue!
    end
  end
end
