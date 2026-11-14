# Writes one sidekiq-cron job from the app's own settings.
#
# Two rules keep the Redis copy of the schedule in step with the settings:
# - The cron expression carries the IANA timezone (e.g. "5 0 * * * Europe/Helsinki"),
#   so the job follows daylight-saving changes instead of a UTC offset frozen at save time.
# - An unchanged job is left alone, so its enqueue history survives restarts and the
#   catch-up of runs missed while the machine slept (reschedule_grace_period) still works.
class CronJobWriter
  Error = Class.new(StandardError)

  class << self
    def upsert(name:, klass:, cron:, description:, queue: "scheduled")
      existing = Sidekiq::Cron::Job.find(name)
      if existing && existing.cron == cron && existing.klass == klass && existing.source == "dynamic"
        return existing
      end

      job = Sidekiq::Cron::Job.new(name: name, cron: cron, class: klass, queue: queue, description: description, source: "dynamic")
      raise Error, "invalid cron job #{name}: #{job.errors.join(", ")}" unless job.valid?
      raise Error, "could not save cron job #{name}" unless job.save

      Rails.logger.info("[CronJobWriter] #{name}: #{cron}")
      job
    end

    def remove(name)
      Sidekiq::Cron::Job.find(name)&.destroy
    end

    # "HH:MM" in the given zone as a cron expression with that zone attached
    def daily_cron(time_str, timezone_name, days: "*")
      hour, minute = parse_time(time_str)
      zone = ActiveSupport::TimeZone[timezone_name.to_s] || ActiveSupport::TimeZone["UTC"]
      "#{minute} #{hour} * * #{days} #{zone.tzinfo.name}"
    end

    def parse_time(time_str)
      return [ 3, 0 ] unless time_str.to_s.match?(/\A\d{1,2}:\d{2}\z/)
      time_str.to_s.split(":").map(&:to_i)
    end
  end
end
