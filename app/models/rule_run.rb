class RuleRun < ApplicationRecord
  include AASM

  # A run still pending after this long has lost its jobs (worker restart,
  # deploy, dead Sidekiq retries). The stale work reaper fails it.
  STALE_AFTER = 2.hours

  EXECUTION_TYPES = %w[manual scheduled].freeze

  belongs_to :rule

  validates :execution_type, inclusion: { in: EXECUTION_TYPES }
  validates :executed_at, presence: true
  validates :transactions_queued, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_processed, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_modified, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_jobs_count, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(executed_at: :desc) }
  scope :for_rule, ->(rule) { where(rule: rule) }
  scope :successful, -> { where(status: "success") }
  scope :stale, -> { where(status: "pending").where(created_at: ...STALE_AFTER.ago) }

  # A run is pending while the rule is being applied and while any async job
  # it queued is outstanding. pending_jobs_count counts both: RuleJob holds one
  # slot for the apply phase itself, and each async job holds one more.
  # Whoever releases the last slot moves the run to success.
  aasm column: :status, requires_lock: true, whiny_persistence: true do
    state :pending, initial: true
    state :success
    state :failed

    event :succeed do
      transitions from: :pending, to: :success, guard: :no_pending_jobs?
    end

    # Terminal failure. Also used by the stale work reaper:
    # RuleRun.stale.find_each { |run| run.fail!("Timed out") }
    event :fail, before: :assign_error_message do
      transitions from: :pending, to: :failed
    end
  end

  # Runs one async job of a rule run and reports its outcome on the run. The block returns
  # how many records it modified. A failure is recorded on the run instead of raised: a
  # retry would call the LLM again for a run that is already reported. Without a run the
  # block just runs, and an error is raised so Sidekiq retries as usual.
  def self.report_job(rule_run_id, job_name)
    rule_run = find_by(id: rule_run_id) if rule_run_id.present?
    return yield unless rule_run

    begin
      modified_count = yield
    rescue => e
      Rails.logger.error("#{job_name} failed for rule run #{rule_run.id}: #{e.class}: #{e.message}")
      rule_run.fail_job!(e, source: job_name)
      return
    end

    rule_run.complete_job!(modified_count: modified_count)
  end

  # Reserve a slot before an async job is queued, so a job that finishes
  # quickly can never take the count to zero while others are still queued.
  def register_job!
    self.class.where(id: id).update_all("pending_jobs_count = pending_jobs_count + 1, updated_at = NOW()")
  end

  # Release a slot. Safe to call on a failed run (the counts still update)
  # and safe against double release (the count never goes below zero).
  def complete_job!(modified_count: 0)
    with_lock do
      self.transactions_modified += modified_count.to_i
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max
      save!
    end

    succeed! if pending_jobs_count.zero? && may_succeed?
  rescue AASM::InvalidTransition
    # Another worker finished or failed the run between our check and the lock.
  end

  # Release a slot and fail the run. Only the call that fails the run writes a debug log
  # entry, so a retried or second failing job does not log the same run twice.
  def fail_job!(error, source: "RuleRun")
    with_lock do
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max
      save!
    end

    return unless may_fail?

    fail!(error)
    capture_failure(error, source)
  rescue AASM::InvalidTransition
  end

  private
    def capture_failure(error, source)
      DebugLogEntry.capture(
        category: "rule_run",
        level: "error",
        message: "Rule run failed: #{error_message.presence || error}",
        source: source,
        family: rule&.family,
        metadata: {
          rule_run_id: id,
          rule_id: rule_id,
          rule_name: rule_name,
          execution_type: execution_type,
          error_class: error.is_a?(Exception) ? error.class.name : nil,
          error_message: error.is_a?(Exception) ? error.message : error.to_s,
          backtrace: error.is_a?(Exception) ? Array(error.backtrace).first(10) : []
        }.compact
      )
    end

    def no_pending_jobs?
      pending_jobs_count.zero?
    end

    def assign_error_message(error = nil)
      return if error.nil?

      self.error_message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    end
end
