# One explicit lifecycle column replaces the is_subscription / suggestion_status
# pair, which could store contradictory combinations:
#   pattern      - detected recurring pattern, not a subscription
#   suggested    - pattern suggested to the user as a subscription
#   dismissed    - suggestion the user dismissed (must not come back)
#   subscription - confirmed subscription (approved or created by the user)
#
# inactive_reason records why a row is inactive: "user" (paused by the user)
# or "stale" (no recent occurrence). Only stale rows are reactivated
# automatically. Existing inactive rows get NULL, which is never reactivated.
#
# The legacy columns stay and the app keeps writing them from the new state,
# so the previous app version keeps working. Drop them in a later migration.
class AddSubscriptionStateToRecurringTransactions < ActiveRecord::Migration[7.2]
  def up
    add_column :recurring_transactions, :subscription_state, :string, null: false, default: "pattern"
    add_column :recurring_transactions, :inactive_reason, :string

    execute <<~SQL
      UPDATE recurring_transactions
      SET subscription_state = CASE
        WHEN is_subscription THEN 'subscription'
        WHEN suggestion_status = 'suggested' THEN 'suggested'
        WHEN suggestion_status = 'dismissed' THEN 'dismissed'
        ELSE 'pattern'
      END
    SQL

    # Approved rows could still carry suggestion_status 'suggested'; normalize the mirror.
    execute <<~SQL
      UPDATE recurring_transactions
      SET suggestion_status = NULL
      WHERE is_subscription AND suggestion_status IS NOT NULL
    SQL

    add_index :recurring_transactions, [ :family_id, :subscription_state ], name: "idx_recurring_txns_family_state"
  end

  def down
    remove_index :recurring_transactions, name: "idx_recurring_txns_family_state"
    remove_column :recurring_transactions, :inactive_reason
    remove_column :recurring_transactions, :subscription_state
  end
end
