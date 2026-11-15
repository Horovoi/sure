# Savings goals (w2-goals savings-goals). Fork-native: one file with every final goal
# column, in place of upstream's six migrations. Pledges have their own migration
# (goal-pledges), stamped after this one.
class CreateGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :target_date
      t.string :color
      t.string :icon
      t.text :notes
      t.string :state, null: false, default: "active"

      # one_off: reached once, then closed. maintained: a reserve to hold (no target date).
      t.string :kind, null: false, default: "one_off"
      # balance: live account balance. contributions: net money put in, without market
      # gains (the default for goals funded by investment or crypto accounts).
      t.string :progress_basis, null: false, default: "balance"
      # fixed: the typed target. months_of_expenses: target_months times the median
      # monthly spend, rewritten by RefreshMaintainedGoalTargetsJob each fiscal month.
      t.string :target_mode, null: false, default: "fixed"
      t.integer :target_months

      # Frozen when the goal completes, so spending the money afterwards does not walk
      # a finished goal back down. nil while the goal is live.
      t.decimal :completed_amount, precision: 19, scale: 4
      t.datetime :completed_at

      # Money spent out of the goal on what it was for; progress counts it as found.
      t.decimal :consumed_amount, precision: 19, scale: 4, null: false, default: 0

      t.timestamps
    end

    add_index :goals, [ :family_id, :state ]

    add_check_constraint :goals, "char_length(name) <= 255", name: "chk_goals_name_length"
    add_check_constraint :goals, "target_amount > 0", name: "chk_goals_target_amount_positive"
    add_check_constraint :goals, "state IN ('active','paused','completed','archived')", name: "chk_goals_state_enum"
    add_check_constraint :goals, "kind IN ('one_off','maintained')", name: "chk_goals_kind_enum"
    add_check_constraint :goals, "progress_basis IN ('balance','contributions')", name: "chk_goals_progress_basis_enum"
    add_check_constraint :goals, "target_mode IN ('fixed','months_of_expenses')", name: "chk_goals_target_mode_enum"
    add_check_constraint :goals, "target_months IS NULL OR target_months > 0", name: "chk_goals_target_months_positive"
    add_check_constraint :goals, "consumed_amount >= 0", name: "chk_goals_consumed_amount_non_negative"

    create_table :goal_accounts, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      # RESTRICT: Account has_many :goal_accounts, dependent: :destroy, so a deleted
      # account removes its links first; a raw delete that skips that is refused.
      t.references :account, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      # NULL: the whole account balance. A number: a fixed earmark in the account's currency.
      t.decimal :allocated_amount, precision: 19, scale: 4

      t.timestamps
    end

    add_index :goal_accounts, [ :goal_id, :account_id ], unique: true, name: "index_goal_accounts_on_goal_and_account"
    add_check_constraint :goal_accounts, "allocated_amount IS NULL OR allocated_amount >= 0",
                         name: "chk_goal_accounts_allocation_non_negative"
  end
end
