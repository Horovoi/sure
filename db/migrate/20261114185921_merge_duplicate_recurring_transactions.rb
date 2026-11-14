# One-time data fix for duplicate recurring transactions.
#
# The identifier used to look rows up by their exact average amount, which
# drifts (FX conversion, price changes), so every drift created a new row.
# Identity is now (family, merchant or name, currency). This merges the
# duplicates per identity key:
#   - the keeper is the most informative row: a subscription or manual row
#     first, then a dismissed, then a suggested row, then the latest
#     last_occurrence_date
#   - transactions linked to a merged row are re-pointed to the keeper
#   - merged rows are deleted, except other subscription or manual rows,
#     which the user curated and are never deleted here
#
# Idempotent: a second run finds nothing to merge.
class MergeDuplicateRecurringTransactions < ActiveRecord::Migration[7.2]
  def up
    before = select_value("SELECT COUNT(*) FROM recurring_transactions").to_i

    execute "DROP TABLE IF EXISTS recurring_merge"
    execute <<~SQL
      CREATE TEMP TABLE recurring_merge AS
      WITH ranked AS (
        SELECT
          id,
          (subscription_state = 'subscription' OR manual) AS protected,
          ROW_NUMBER() OVER w AS rank,
          FIRST_VALUE(id) OVER w AS keeper_id
        FROM recurring_transactions
        WINDOW w AS (
          PARTITION BY
            family_id,
            CASE WHEN merchant_id IS NOT NULL THEN 'merchant:' || merchant_id::text ELSE 'name:' || COALESCE(name, '') END,
            currency
          ORDER BY
            (subscription_state = 'subscription' OR manual) DESC,
            CASE subscription_state WHEN 'dismissed' THEN 0 WHEN 'suggested' THEN 1 ELSE 2 END,
            last_occurrence_date DESC,
            updated_at DESC,
            id
        )
      )
      SELECT id AS loser_id, keeper_id
      FROM ranked
      WHERE rank > 1 AND NOT protected
    SQL

    execute <<~SQL
      UPDATE transactions
      SET recurring_transaction_id = recurring_merge.keeper_id
      FROM recurring_merge
      WHERE transactions.recurring_transaction_id = recurring_merge.loser_id
    SQL

    execute <<~SQL
      DELETE FROM active_storage_attachments
      WHERE record_type = 'RecurringTransaction'
        AND record_id IN (SELECT loser_id FROM recurring_merge)
    SQL

    execute <<~SQL
      DELETE FROM recurring_transactions
      WHERE id IN (SELECT loser_id FROM recurring_merge)
    SQL

    execute "DROP TABLE recurring_merge"

    after = select_value("SELECT COUNT(*) FROM recurring_transactions").to_i
    say "recurring_transactions: #{before} rows before, #{after} after (#{before - after} duplicates merged)"
  end

  def down
    # Deleted duplicates cannot be restored; the merge is harmless to keep.
  end
end
