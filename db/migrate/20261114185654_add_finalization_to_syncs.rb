class AddFinalizationToSyncs < ActiveRecord::Migration[7.2]
  def up
    # Set once, under a row lock, when post-sync work has run; makes finalization idempotent
    add_column :syncs, :finalized_at, :datetime
    # Set when a sync is requested while this one is already running; one follow-up runs after it
    add_column :syncs, :rerun_requested, :boolean, null: false, default: false

    # Syncs that already finished count as finalized, so a parent never waits on them
    execute <<~SQL
      UPDATE syncs
      SET finalized_at = COALESCE(completed_at, failed_at, updated_at)
      WHERE status IN ('completed', 'failed', 'stale')
    SQL
  end

  def down
    remove_column :syncs, :rerun_requested
    remove_column :syncs, :finalized_at
  end
end
