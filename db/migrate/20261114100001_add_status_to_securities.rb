# Replaces the single `offline` boolean with an explicit price status, so a security the
# user entered by hand ("manual") is no longer confused with one the provider stopped
# pricing ("unavailable"). `offline` stays as a mirror (offline = not fetchable) so the
# previous app version keeps working; it can be dropped later.
class AddStatusToSecurities < ActiveRecord::Migration[7.2]
  def up
    add_column :securities, :status, :string, null: false, default: "online"
    add_index :securities, :status

    # One-time data fix (idempotent: derived from columns this migration does not change).
    # - offline after more than MAX_CONSECUTIVE_FAILURES (5) failed health checks -> unavailable
    # - any other offline security was created by the Resolver (no provider match) -> manual
    # - online with some failed checks -> degraded
    execute <<~SQL
      UPDATE securities
      SET status = CASE
        WHEN offline AND failed_fetch_count > 5 THEN 'unavailable'
        WHEN offline THEN 'manual'
        WHEN failed_fetch_count > 0 THEN 'degraded'
        ELSE 'online'
      END
    SQL
  end

  def down
    remove_index :securities, :status
    remove_column :securities, :status
  end
end
