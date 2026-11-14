module Syncable
  extend ActiveSupport::Concern

  included do
    has_many :syncs, as: :syncable, dependent: :destroy
  end

  class_methods do
    # Answers `syncing?` for a whole list of records with one query. Use on pages
    # that show many syncables, where each row would otherwise run its own lookup.
    def preload_syncing(records)
      records = records.to_a
      return records if records.empty?

      syncing_ids = Sync.visible
                        .where(syncable_type: polymorphic_name, syncable_id: records.map(&:id))
                        .distinct
                        .pluck(:syncable_id)
                        .to_set

      records.each { |record| record.preloaded_syncing = syncing_ids.include?(record.id) }
    end
  end

  attr_writer :preloaded_syncing

  def syncing?
    return @preloaded_syncing unless @preloaded_syncing.nil?

    syncs.visible.any?
  end

  # Schedules a sync for syncable. At most one sync per record is in flight:
  # - a pending sync absorbs the request (its window widens if needed);
  # - a running sync is flagged to run once more when it finishes, so a change made
  #   during a sync (an edited transaction) is never dropped;
  # - a sync older than Sync::VISIBLE_FOR has lost its job; a new one is created and the
  #   reaper finalizes the old one.
  def sync_later(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    Sync.transaction do
      with_lock do
        sync = self.syncs.visible.first
        # Lock it so its own finalization can't slip between this check and the rerun flag:
        # either it sees the flag, or we see it already finished and start a new sync.
        sync&.lock!
        sync = nil if sync && (sync.finalized_at.present? || !(sync.pending? || sync.syncing?))

        if sync&.syncing?
          Rails.logger.info("Sync #{sync.id} is running; requesting a rerun when it finishes")
          sync.request_rerun!
          sync.update!(parent: parent_sync) if parent_sync && !sync.parent_id
        elsif sync
          Rails.logger.info("There is an existing pending sync, expanding window if needed (#{sync.id})")
          sync.expand_window_if_needed(window_start_date, window_end_date)

          # Update parent relationship if one is provided and sync doesn't already have a parent
          if parent_sync && !sync.parent_id
            sync.update!(parent: parent_sync)
          end
        else
          sync = self.syncs.create!(
            parent: parent_sync,
            window_start_date: window_start_date,
            window_end_date: window_end_date
          )

          SyncJob.perform_later(sync)
        end

        sync
      end
    end
  end

  def perform_sync(sync)
    syncer.perform_sync(sync)
  end

  def perform_post_sync
    syncer.perform_post_sync
  end

  def broadcast_sync_complete
    sync_broadcaster.broadcast
  end

  def sync_error
    latest_sync&.error || latest_sync&.children&.map(&:error)&.compact&.first
  end

  def last_synced_at
    latest_completed_sync&.completed_at
  end

  def last_sync_created_at
    latest_sync&.created_at
  end

  private
    def latest_sync
      syncs.ordered.first
    end

    def latest_completed_sync
      syncs.completed.ordered.first
    end

    def syncer
      self.class::Syncer.new(self)
    end

    def sync_broadcaster
      self.class::SyncCompleteEvent.new(self)
    end
end
