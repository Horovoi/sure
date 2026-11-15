# frozen_string_literal: true

# Runs every job the app enqueued on ActiveJob's :test adapter, in the order the queue
# would: due jobs first (oldest due time, then enqueue order), then waits until the next
# scheduled one. When the queue is empty but a monobank account is backing off after a
# failed fetch, it waits until the back-off ends and asks the item to sync again, as the
# hourly sync would. Stops when nothing is left to do, or at a job or time cap.
#
# wait: called with the Time to wait for. The staging run sleeps; the integration test
# travels (travel_to), so Time.now, the fake's clock and the app's clock move together.
module MonobankFake
  class Drain
    Error = Class.new(StandardError)

    attr_reader :performed, :errors, :kicks

    def initialize(adapter: ActiveJob::Base.queue_adapter, wait:, max_jobs: 2_000, max_duration: 2.hours,
                   raise_errors: true, log: nil, now: -> { Time.current })
      unless adapter.respond_to?(:enqueued_jobs)
        raise Error, "the drain needs ActiveJob's :test adapter (got #{adapter.class})"
      end

      @adapter = adapter
      @wait = wait
      @max_jobs = max_jobs
      @max_duration = max_duration
      @raise_errors = raise_errors
      @log = log
      @now = now
      @performed = []
      @errors = []
      @kicks = 0
    end

    # Runs until quiet. item: a MonobankItem whose back-offs and remaining windows are
    # followed up (nil: only the queue).
    def run(item = nil)
      deadline = @now.call + @max_duration
      idle_kicks = 0

      loop do
        raise Error, "more than #{@max_jobs} jobs; stopping" if @performed.size >= @max_jobs

        if (job = next_due_job)
          perform(job)
          idle_kicks = 0
          next
        end

        if (next_at = next_scheduled_at)
          raise Error, "next job at #{next_at} is after the #{@max_duration.inspect} cap" if next_at > deadline

          @wait.call(next_at)
          raise Error, "waiting did not reach #{next_at}" if @now.call < next_at
          next
        end

        break unless item

        wake_at, reason = follow_up(item)
        break unless wake_at

        idle_kicks += 1
        raise Error, "no progress after #{idle_kicks - 1} follow-up syncs (#{reason})" if idle_kicks > 3
        raise Error, "#{reason} at #{wake_at} is after the #{@max_duration.inspect} cap" if wake_at > deadline

        @wait.call(wake_at) if wake_at > @now.call
        say("follow-up sync: #{reason}")
        @kicks += 1
        item.reload.sync_later
      end

      self
    end

    # Waits (sleeps or travels) until time
    def wait_until(time)
      @wait.call(time) if time > @now.call
    end

    private

      def enqueued
        @adapter.enqueued_jobs
      end

      def scheduled_at(job)
        at = job[:at] || job["scheduled_at"]
        case at
        when nil then nil
        when Numeric then Time.at(at)
        when String then Time.zone.parse(at)
        else at
        end
      end

      def next_due_job
        now = @now.call
        due = enqueued.each_with_index.select { |job, _| (at = scheduled_at(job)).nil? || at <= now }
        return if due.empty?

        job, _ = due.min_by { |candidate, index| [ scheduled_at(candidate) || Time.at(0), index ] }
        enqueued.delete_at(enqueued.index { |candidate| candidate.equal?(job) })
        job
      end

      def next_scheduled_at
        enqueued.filter_map { |job| scheduled_at(job) }.min
      end

      def perform(job)
        say("perform #{job['job_class']} #{scheduled_at(job)&.iso8601}")
        @performed << job
        ActiveJob::Base.execute(job.except(:job, :args, :queue, :priority, :at).transform_keys(&:to_s))
      rescue StandardError => e
        @errors << { job: job["job_class"], error: "#{e.class}: #{e.message}" }
        say("  #{job['job_class']} raised #{e.class}: #{e.message}")
        raise if @raise_errors
      end

      # With the queue empty the fetch chain has ended (it reschedules itself while the
      # plan has a window). What is left is an account that skipped its windows after a
      # failed fetch: the time its back-off ends, when a sync picks it up again. Nothing
      # else is followed up: an open hold keeps a forward refresh due (FetchPlan), which
      # the next hourly sync makes, so "a window is due" alone never means "kick a sync".
      def follow_up(item)
        backoff = MonobankAccount.where(monobank_item_id: item.id).where("fetch_failures > 0 AND next_fetch_after > ?", @now.call).minimum(:next_fetch_after)
        [ backoff + 1.second, "an account backs off until #{backoff.iso8601}" ] if backoff
      end

      def say(message)
        @log&.puts("  [drain] #{message}")
      end
  end
end
