# A super-admin event log for failures that would otherwise only reach the Rails log:
# failed syncs, reaped work, failed AI rule runs. Rows are deleted after
# DEBUG_LOG_RETENTION_DAYS (90 by default) by DebugLogCleanupJob. Deleting a family,
# account or user keeps its entries and only clears the reference.
class CreateDebugLogEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :debug_log_entries, id: :uuid do |t|
      t.string :category, null: false
      t.string :level, null: false
      t.text :message, null: false
      t.string :source, null: false
      t.jsonb :metadata, null: false, default: {}
      t.references :family, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :provider_key

      t.timestamps
    end

    add_check_constraint :debug_log_entries,
      "level IN ('debug', 'info', 'warn', 'error')",
      name: "chk_debug_log_entries_level"

    add_index :debug_log_entries, :created_at
    add_index :debug_log_entries, [ :category, :created_at ]
    add_index :debug_log_entries, :level
  end

  def down
    drop_table :debug_log_entries
  end
end
