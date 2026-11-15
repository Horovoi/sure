# Goal pledges (w2-goals goal-pledges). Fork-native, stamped after CreateGoals: the user
# says "I just put X into this account for this goal", and the pledge waits for the
# deposit, transfer or balance update that keeps it. Strings with CHECK constraints,
# not PostgreSQL enums, like the rest of the goal tables.
class CreateGoalPledges < ActiveRecord::Migration[8.1]
  def change
    create_table :goal_pledges, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      # RESTRICT: Account has_many :goal_pledges, dependent: :destroy removes them first
      t.references :account, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      # transfer: kept by an inflow transaction. manual_save: also kept by a balance update.
      # No default: GoalPledge takes the account's (Account#default_pledge_kind).
      t.string :kind, null: false
      t.string :status, null: false, default: "open"
      t.datetime :expires_at, null: false
      # The inflow that kept the pledge. A deleted transaction gives the pledge back
      # (Transaction before_destroy); the FK nullify is the backstop for raw deletes.
      t.references :matched_transaction, type: :uuid, index: false,
                   foreign_key: { to_table: :transactions, on_delete: :nullify }
      # The date of the entry that kept it (a transaction or a balance update), for
      # "last pledge kept N days ago"
      t.date :matched_on

      t.timestamps
    end

    add_index :goal_pledges, [ :goal_id, :status ]
    add_index :goal_pledges, [ :status, :expires_at ], where: "status = 'open'", name: "index_goal_pledges_open_by_expiry"
    add_index :goal_pledges, :matched_transaction_id, unique: true, where: "matched_transaction_id IS NOT NULL"

    add_check_constraint :goal_pledges, "amount > 0", name: "chk_goal_pledges_amount_positive"
    add_check_constraint :goal_pledges, "kind IN ('transfer','manual_save')", name: "chk_goal_pledges_kind_enum"
    add_check_constraint :goal_pledges, "status IN ('open','matched','cancelled','expired')", name: "chk_goal_pledges_status_enum"
  end
end
