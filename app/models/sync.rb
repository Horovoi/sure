class Sync < ApplicationRecord
  # StaleWorkReaperJob marks syncs that have not finished within this time as "stale" and
  # finalizes their parents. Syncs take about a second; one this old has lost its job.
  STALE_AFTER = 30.minutes

  # A sync younger than this counts as in flight: it shows as syncing in the UI and new
  # requests for the same record join it instead of starting a second, concurrent sync.
  # Kept equal to STALE_AFTER so "in flight" means the same thing everywhere.
  VISIBLE_FOR = STALE_AFTER

  include AASM

  Error = Class.new(StandardError)

  belongs_to :syncable, polymorphic: true

  belongs_to :parent, class_name: "Sync", optional: true
  has_many :children, class_name: "Sync", foreign_key: :parent_id, dependent: :destroy

  scope :ordered, -> { order(created_at: :desc) }
  scope :incomplete, -> { where("syncs.status IN (?)", %w[pending syncing]) }
  scope :visible, -> { incomplete.where("syncs.created_at > ?", VISIBLE_FOR.ago) }

  after_commit :update_family_sync_timestamp
  after_destroy_commit :finalize_parent_after_destroy

  serialize :sync_stats, coder: JSON

  validate :window_valid

  # Sync state machine
  # requires_lock: every transition reloads the row under FOR UPDATE, so two workers (a
  # redelivered job, the reaper, a child finalizing its parent) can never both move it.
  aasm column: :status, timestamps: true, requires_lock: true, whiny_transitions: true do
    state :pending, initial: true
    state :syncing
    state :completed
    state :failed
    state :stale

    after_all_transitions :handle_transition

    event :start, after_commit: :handle_start_transition do
      transitions from: :pending, to: :syncing
    end

    event :complete, after_commit: :handle_completion_transition do
      transitions from: :syncing, to: :completed
    end

    event :fail, after_commit: :handle_completion_transition do
      transitions from: :syncing, to: :failed
    end

    # Marks a sync that never completed within the expected time window
    event :mark_stale do
      transitions from: %i[pending syncing], to: :stale
    end
  end

  class << self
    # Marks syncs whose job was lost as stale, then finalizes them so their parents finish
    # and post-sync work (transfer matching, rules) still runs. Returns the number reaped.
    def clean
      count = 0
      incomplete.where("syncs.created_at < ?", STALE_AFTER.ago).find_each do |sync|
        next unless sync.mark_stale_if_incomplete!
        count += 1
        sync.send(:capture_stale)
        sync.finalize_if_all_children_finalized
      rescue => e
        # One sync that cannot be finalized must not stop the rest of the sweep
        Rails.logger.error("Could not clean stale sync #{sync.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
      end
      count
    end
  end

  def mark_stale_if_incomplete!
    with_lock do
      return false unless may_mark_stale?
      mark_stale!
      true
    end
  end

  def perform
    Rails.logger.tagged("Sync", id, syncable_type, syncable_id) do
      # A redelivered job, or one for a sync another worker already claimed, does nothing
      unless claim!
        Rails.logger.warn("Sync #{id} is not pending (#{status}).  Skipping sync.")
        return
      end

      begin
        Time.use_zone(family_time_zone) do
          if syncable.nil?
            fail_with!("Syncable record was deleted")
          elsif syncable.respond_to?(:scheduled_for_deletion?) && syncable.scheduled_for_deletion?
            fail_with!("Syncable record is scheduled for deletion")
          else
            syncable.perform_sync(self)
          end
        end
      rescue => e
        fail_with!(e.message, error: e)
        report_error(e)
      ensure
        # Every exit path finalizes, so a parent never waits on a child that returned early
        finalize_if_all_children_finalized
      end
    end
  end

  # Finalizes this sync (and then its parent) once all of its children have finished.
  # Status moves to completed/failed if still syncing; post-sync work runs exactly once,
  # after the transaction commits, whatever the final status.
  def finalize_if_all_children_finalized
    finalized_now = Sync.transaction do
      lock!

      next false if finalized_at.present? || pending?
      next false unless all_children_finalized?

      if syncing?
        has_failed_children? ? fail! : complete!
      end

      update_column(:finalized_at, Time.current)
      true
    end

    if finalized_now
      Time.use_zone(family_time_zone) { perform_post_sync }
      rerun_if_requested
    end

    # If this sync has a parent, try to finalize it so the child status propagates up the chain.
    parent&.finalize_if_all_children_finalized
  end

  # Called when a sync is requested for a record that is already syncing: instead of
  # dropping the request (and the edit that caused it), run once more when this one ends.
  def request_rerun!
    update_column(:rerun_requested, true) unless rerun_requested?
  end

  # If a sync is pending, we can adjust the window if new syncs are created with a wider window.
  def expand_window_if_needed(new_window_start_date, new_window_end_date)
    return unless pending?
    return if self.window_start_date.nil? && self.window_end_date.nil? # already as wide as possible

    earliest_start_date = if self.window_start_date && new_window_start_date
      [ self.window_start_date, new_window_start_date ].min
    else
      nil
    end

    latest_end_date = if self.window_end_date && new_window_end_date
      [ self.window_end_date, new_window_end_date ].max
    else
      nil
    end

    update(
      window_start_date: earliest_start_date,
      window_end_date: latest_end_date
    )
  end

  private
    # pending -> syncing as one atomic compare-and-set: of two workers holding the same
    # sync (a redelivered job), exactly one wins. No reload, so the loaded syncable stays.
    def claim!
      now = Time.current
      claimed = Sync.where(id: id, status: "pending").update_all(status: "syncing", syncing_at: now, updated_at: now) == 1
      return false unless claimed

      # Re-read the window: a request may have widened it after this job loaded the row
      window_start, window_end = Sync.where(id: id).pick(:window_start_date, :window_end_date)
      self.status = "syncing"
      self.syncing_at = now
      self.updated_at = now
      self.window_start_date = window_start
      self.window_end_date = window_end
      clear_attribute_changes(%w[status syncing_at updated_at window_start_date window_end_date])
      Rails.logger.info("changing from pending to syncing (event: start)")
      report_warnings
      true
    end

    def fail_with!(message, error: nil)
      with_lock { fail! if may_fail? }
      update_column(:error, message)
      capture_failure(message, error)
    end

    # The Settings > Debug log keeps failed syncs, which otherwise only reach the Rails log
    def capture_failure(message, error)
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Sync failed: #{message}",
        source: "Sync",
        family: family_or_nil,
        account: syncable.is_a?(Account) ? syncable : nil,
        metadata: {
          sync_id: id,
          syncable_type: syncable_type,
          syncable_id: syncable_id,
          parent_id: parent_id,
          error_class: error&.class&.name,
          backtrace: Array(error&.backtrace).first(10)
        }.compact
      )
    end

    def capture_stale
      DebugLogEntry.capture(
        category: "stale_work",
        level: "warn",
        message: "Sync marked stale: not finished within #{STALE_AFTER.inspect}",
        source: "StaleWorkReaperJob",
        family: family_or_nil,
        account: syncable.is_a?(Account) ? syncable : nil,
        metadata: { record_type: "Sync", record_id: id, syncable_type: syncable_type, syncable_id: syncable_id, created_at: created_at&.iso8601 }
      )
    end

    def family_or_nil
      family
    rescue StandardError
      nil
    end

    def rerun_if_requested
      return unless rerun_requested? && syncable.present?
      Rails.logger.info("Sync #{id} finished with a rerun requested; scheduling a follow-up sync")
      syncable.sync_later
    end

    def finalize_parent_after_destroy
      return unless parent_id
      Sync.find_by(id: parent_id)&.finalize_if_all_children_finalized
    rescue => e
      report_error(e)
    end

    def family_time_zone
      family&.resolved_time_zone || "UTC"
    rescue StandardError
      "UTC"
    end

    def log_status_change
      Rails.logger.info("changing from #{aasm.from_state} to #{aasm.to_state} (event: #{aasm.current_event})")
    end

    # A stale child lost its job part-way, so its work is incomplete: that is a failure
    def has_failed_children?
      children.where(status: %w[failed stale]).exists?
    end

    # A child counts as done only when its whole subtree is: finalized_at is set once its
    # own children have finished and its post-sync has run.
    def all_children_finalized?
      !children.where(finalized_at: nil).exists?
    end

    def perform_post_sync
      Rails.logger.info("Performing post-sync for #{syncable_type} (#{syncable_id})")
      syncable.perform_post_sync
      syncable.broadcast_sync_complete
    rescue => e
      Rails.logger.error("Error performing post-sync for #{syncable_type} (#{syncable_id}): #{e.message}")
      report_error(e)
    end

    def report_error(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(sync_id: id)
      end
    end

    def report_warnings
      todays_sync_count = syncable.syncs.where(created_at: Date.current.all_day).count

      if todays_sync_count > 10
        Sentry.capture_exception(
          Error.new("#{syncable_type} (#{syncable.id}) has exceeded 10 syncs today (count: #{todays_sync_count})"),
          level: :warning
        )
      end
    end

    def handle_start_transition
      report_warnings
    end

    def handle_transition
      log_status_change
    end

    # Bumped on failure too: a failed sync may still have written data, and this
    # timestamp is part of the balance sheet cache key.
    def handle_completion_transition
      family&.touch(:latest_sync_completed_at)
    end

    def window_valid
      if window_start_date && window_end_date && window_start_date > window_end_date
        errors.add(:window_end_date, "must be greater than window_start_date")
      end
    end

    # A family destroyed with its syncs (User#purge) commits them with it: there is
    # nothing left to touch, and touch raises on a destroyed record
    def update_family_sync_timestamp
      sync_family = family
      sync_family.touch(:latest_sync_activity_at) if sync_family&.persisted?
    end

    def family
      if syncable.is_a?(Family)
        syncable
      else
        syncable&.family
      end
    end
end
