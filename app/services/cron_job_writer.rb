# Writes one sidekiq-cron job from the app's own settings.
#
# Three rules keep the Redis copy of the schedule in step with the settings:
# - The cron expression carries the IANA timezone (e.g. "5 0 * * * Europe/Kyiv"),
#   so the job follows daylight-saving changes instead of a UTC offset frozen at save time.
# - An unchanged job is left alone, so its enqueue history survives restarts and the
#   catch-up of runs missed while the machine slept (reschedule_grace_period) still works.
# - Every job is written with active_job: true, so a tick always pushes an Active Job
#   payload. Without the flag, sidekiq-cron pushes a raw Sidekiq::Job payload when the
#   process firing the tick cannot resolve the class (another code version polling the
#   same Redis), and the worker then fails on every retry with "undefined method jid=".
class CronJobWriter
  Error = Class.new(StandardError)

  class << self
    def upsert(name:, klass:, cron:, description:, queue: "scheduled")
      existing = Sidekiq::Cron::Job.find(name)
      return existing if unchanged?(existing, cron: cron, klass: klass)

      job = Sidekiq::Cron::Job.new(name: name, cron: cron, class: klass, queue: queue, description: description, source: "dynamic", active_job: true)
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

    private
      # A job saved before the active_job flag existed counts as changed, so it is
      # written again once with the flag and then left alone.
      def unchanged?(existing, cron:, klass:)
        existing.present? &&
          existing.cron == cron &&
          existing.klass == klass &&
          existing.source == "dynamic" &&
          existing.to_hash[:active_job] == "1"
      end
  end
end
