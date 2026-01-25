class ScheduledJobsManager
  CONFIGURABLE_JOBS = {
    data_cleaner: { class: "DataCleanerJob", offset: 0, cron_name: "clean_data" },
    security_health_check: { class: "SecurityHealthCheckJob", offset: 15, cron_name: "run_security_health_checks" },
    subscription_transactions: { class: "GenerateSubscriptionTransactionsJob", offset: 30, cron_name: "generate_subscription_transactions" }
  }.freeze

  class << self
    def sync!
      CONFIGURABLE_JOBS.each do |job_key, config|
        upsert_job(job_key, config)
      end
    end

    def effective_time_for(job_key)
      job_key = job_key.to_sym
      custom_time = Setting.public_send("#{job_key}_time")
      return custom_time if custom_time.present?

      base_time = Setting.scheduled_jobs_start_time || "03:00"
      offset = CONFIGURABLE_JOBS.dig(job_key, :offset) || 0
      add_minutes(base_time, offset)
    end

    def effective_times
      CONFIGURABLE_JOBS.keys.index_with { |key| effective_time_for(key) }
    end

    def timezone
      Setting.scheduled_jobs_timezone.presence || "UTC"
    end

    def has_custom_times?
      CONFIGURABLE_JOBS.keys.any? do |job_key|
        Setting.public_send("#{job_key}_time").present?
      end
    end

    def reset_custom_times!
      CONFIGURABLE_JOBS.keys.each do |job_key|
        Setting.public_send("#{job_key}_time=", nil)
      end
      sync!
    end

    private

      def upsert_job(job_key, config)
        time_str = effective_time_for(job_key)
        timezone_str = timezone

        cron = build_cron_expression(time_str, timezone_str, job_key)

        job = Sidekiq::Cron::Job.create(
          name: config[:cron_name],
          cron: cron,
          class: config[:class],
          queue: "scheduled",
          description: job_description(job_key)
        )

        if job.nil? || (job.respond_to?(:valid?) && !job.valid?)
          error_msg = job.respond_to?(:errors) ? job.errors.to_a.join(", ") : "unknown error"
          Rails.logger.error("[ScheduledJobsManager] Failed to create cron job #{job_key}: #{error_msg}")
          raise StandardError, "Failed to create schedule for #{job_key}: #{error_msg}"
        end

        Rails.logger.info("[ScheduledJobsManager] Updated #{job_key} with schedule: #{cron} (#{time_str} #{timezone_str})")
        job
      end

      def build_cron_expression(time_str, timezone_str, job_key)
        hour, minute = parse_time(time_str)
        tz = ActiveSupport::TimeZone[timezone_str] || ActiveSupport::TimeZone["UTC"]

        local_time = tz.now.change(hour: hour, min: minute, sec: 0)
        utc_time = local_time.utc

        # SecurityHealthCheckJob runs only on weekdays
        if job_key == :security_health_check
          "#{utc_time.min} #{utc_time.hour} * * 1-5"
        else
          "#{utc_time.min} #{utc_time.hour} * * *"
        end
      end

      def parse_time(time_str)
        return [ 3, 0 ] unless time_str.present? && time_str.match?(/\A\d{1,2}:\d{2}\z/)
        time_str.split(":").map(&:to_i)
      end

      def add_minutes(time_str, minutes)
        hour, minute = parse_time(time_str)
        total_minutes = hour * 60 + minute + minutes

        new_hour = (total_minutes / 60) % 24
        new_minute = total_minutes % 60

        format("%02d:%02d", new_hour, new_minute)
      end

      def job_description(job_key)
        case job_key
        when :data_cleaner
          "Cleans up old data (e.g., expired merchant associations)"
        when :security_health_check
          "Runs security health checks to detect issues with security data"
        when :subscription_transactions
          "Generates transactions for due subscriptions on manual accounts"
        end
      end
  end
end
