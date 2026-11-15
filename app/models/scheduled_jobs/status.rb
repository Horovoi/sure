require "sidekiq/api"

# What Settings > Self-Hosting shows about the cron schedule: for each job that should be
# scheduled, its last run, its next run and whether something is wrong with it, plus
# whether a Sidekiq worker is alive to run it.
#
# The real failure this answers is a cron entry that silently went missing from Redis,
# so the expected jobs come from the code (config/schedule.yml and the schedulers that
# write jobs from Settings), not from Redis: a job that Redis does not know shows as
# "not scheduled". Read-only: it never writes to Redis.
module ScheduledJobs
  class Status
    # A run counts as missed when it was due this long ago and has not happened
    OVERDUE_GRACE = 1.hour
    # Sidekiq processes write a heartbeat about every 10 seconds
    WORKER_BEAT_WINDOW = 60.seconds
    SCHEDULE_FILE = Rails.root.join("config/schedule.yml")
    # Written by config/schedule.yml (backup bundle); listed here too so the daily backup
    # stays expected even if its entry is removed from the file by mistake
    FULL_BACKUP_JOB_NAME = "full_backup"

    STATES = %i[ok overdue disabled not_scheduled].freeze
    # Problems first, then the rest by name
    STATE_ORDER = { not_scheduled: 0, overdue: 1, disabled: 2, ok: 3 }.freeze

    REDIS_ERRORS = [
      RedisClient::Error,
      (Redis::BaseError if defined?(Redis::BaseError)),
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      SocketError,
      IOError
    ].compact.freeze

    Entry = Data.define(:name, :cron, :state, :last_run_at, :next_run_at) do
      def problem?
        state != :ok
      end
    end

    attr_reader :now

    def initialize(now: Time.current)
      @now = now
    end

    # False when Redis could not be read; the page then says so instead of failing
    def available?
      load
      @available
    end

    def worker_alive?
      load
      @worker_alive
    end

    def entries
      load
      @entries
    end

    private
      def load
        return if defined?(@available)

        cron_jobs = Sidekiq::Cron::Job.all.index_by(&:name)
        @worker_alive = worker_beating?
        names = (expected_job_names + cron_jobs.keys).uniq
        @entries = names
          .map { |name| cron_jobs[name] ? entry_for(cron_jobs[name]) : missing_entry(name) }
          .sort_by { |entry| [ STATE_ORDER.fetch(entry.state), entry.name ] }
        @available = true
      rescue *REDIS_ERRORS => e
        Rails.logger.warn("[ScheduledJobs::Status] Redis unavailable: #{e.class}: #{e.message}")
        @entries = []
        @worker_alive = false
        @available = false
      end

      def expected_job_names
        names = schedule_file_job_names
        names += ScheduledJobsManager::CONFIGURABLE_JOBS.values.map { |config| config[:cron_name] }
        names << AutoSyncScheduler::JOB_NAME if Setting.auto_sync_enabled?
        names << FULL_BACKUP_JOB_NAME
        names.uniq
      end

      def schedule_file_job_names
        schedule = YAML.safe_load_file(SCHEDULE_FILE)
        schedule.is_a?(Hash) ? schedule.keys.map(&:to_s) : []
      rescue Errno::ENOENT, Psych::Exception => e
        Rails.logger.warn("[ScheduledJobs::Status] could not read #{SCHEDULE_FILE}: #{e.class}: #{e.message}")
        []
      end

      def entry_for(job)
        cron = parse_cron(job.cron)
        last_run_at = job.last_enqueue_time&.in_time_zone
        enabled = job.enabled?

        Entry.new(
          name: job.name,
          cron: job.cron,
          state: state_for(enabled:, cron:, last_run_at:),
          last_run_at: last_run_at,
          next_run_at: (enabled && cron) ? cron.next_time(now.utc).to_t.in_time_zone : nil
        )
      end

      def missing_entry(name)
        Entry.new(name: name, cron: nil, state: :not_scheduled, last_run_at: nil, next_run_at: nil)
      end

      # Overdue: a run was due more than OVERDUE_GRACE ago and the last run is older than
      # that due time. Taking the due time from the cron expression, not a fixed interval,
      # keeps weekday-only jobs from looking late on Monday morning. A job that has never
      # run has no last run to compare, so it is not reported as overdue.
      def state_for(enabled:, cron:, last_run_at:)
        return :disabled unless enabled
        return :ok if cron.nil? || last_run_at.nil?

        due_at = cron.previous_time((now - OVERDUE_GRACE).utc).to_t
        last_run_at < due_at ? :overdue : :ok
      end

      # Same parser as sidekiq-cron for plain cron lines; the expression may end with a
      # time zone ("0 4 * * * Europe/Kyiv")
      def parse_cron(expression)
        Fugit.parse_cron(expression.to_s)
      rescue ArgumentError
        nil
      end

      # ProcessSet.new(false) skips the cleanup of dead processes, which writes to Redis
      def worker_beating?
        cutoff = (now - WORKER_BEAT_WINDOW).to_f
        Sidekiq::ProcessSet.new(false).any? { |process| process["beat"].to_f >= cutoff }
      end
  end
end
