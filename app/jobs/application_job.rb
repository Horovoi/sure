class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked
  discard_on ActiveJob::DeserializationError
  queue_as :low_priority # default queue

  # A job about one family's data runs in that family's time zone, like its web
  # requests do, so "today" (Date.current) means the same day in both. Without it,
  # jobs ran in UTC and disagreed with the browser for hours after local midnight.
  around_perform do |job, block|
    job.send(:in_time_zone_of, job.send(:family_for_time_zone), &block)
  end

  private
    # The family this job is about: its first argument, or that record's family. A job
    # that names its family some other way overrides this; a job that loops over
    # families wraps each one in in_time_zone_of instead.
    def family_for_time_zone
      subject = arguments.first
      subject.is_a?(Family) ? subject : subject.try(:family)
    rescue StandardError
      nil
    end

    # A family whose time zone cannot be resolved runs in UTC (Family#resolved_time_zone)
    def in_time_zone_of(family, &block)
      zone = family.try(:resolved_time_zone)
      zone ? Time.use_zone(zone, &block) : block.call
    end

    # Runs the block under a session-level Postgres advisory lock named by `name`, so the
    # same work never runs twice at once. Does not wait: returns false, without running the
    # block, when another job holds the lock.
    def with_advisory_lock(name)
      connection = ActiveRecord::Base.connection
      # Advisory locks take an integer key
      key = Digest::MD5.hexdigest(name).to_i(16) % (2**31)
      return false unless connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", key ]))

      begin
        yield
      ensure
        connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", key ]))
      end

      true
    end
end
