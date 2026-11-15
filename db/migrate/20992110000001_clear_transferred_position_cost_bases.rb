# A position that took in a transfer has no cost basis this app can know: the units were
# acquired somewhere else, at a price nothing here recorded. The calculators used to count
# the transfer's own price as a purchase, and the materializer stored that figure as
# "calculated". Holding#avg_cost reads the stored figure first, so it stands until the
# account materializes again, which for a manual account may be never.
#
# Clears only figures this app worked out (source calculated or none, not locked) on rows
# dated on or after a transfer IN of the same security. A transfer out leaves the
# remaining units with the cost they were really bought at, and a manual or provider
# figure is somebody's statement of what the position cost: both stay.
#
# Production has no transfer trades, so this is expected to touch 0 rows. It updates
# rows and deletes none.
class ClearTransferredPositionCostBases < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE holdings
      SET cost_basis = NULL, cost_basis_source = NULL
      WHERE cost_basis IS NOT NULL
        AND cost_basis_locked = false
        AND (cost_basis_source IS NULL OR cost_basis_source = 'calculated')
        AND EXISTS (
          SELECT 1
          FROM trades
          JOIN entries ON entries.entryable_id = trades.id
                      AND entries.entryable_type = 'Trade'
          WHERE trades.security_id = holdings.security_id
            AND entries.account_id = holdings.account_id
            AND trades.investment_activity_label = 'Transfer'
            AND trades.qty > 0
            AND entries.date <= holdings.date
        )
    SQL
  end

  # The cleared figures were wrong and the right answer is "unknown": putting them back
  # would mean recomputing the same error.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
