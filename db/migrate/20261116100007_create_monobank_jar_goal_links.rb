# A monobank jar with a savings target becomes a Sure goal (MonobankAccount::JarGoal).
# What the sync remembers about that goal is kept per family and jar (monobank's jar id,
# stable across tokens), not on monobank_accounts: disconnecting monobank deletes those
# rows, and a reconnected jar must find its goal again and must not bring back a goal
# the owner deleted.
#
# goal_id: the goal; deleting it clears the link (dismissed_at records that the owner
# did it, so the goal is not made again). funding_account_id: the Sure account the sync
# put the goal's whole-account link on, so a relinked jar moves that link and no other.
# synced_target, synced_title: what the last sync took from monobank.
class CreateMonobankJarGoalLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :monobank_jar_goal_links, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :jar_id, null: false
      t.references :goal, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :funding_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.decimal :synced_target, precision: 19, scale: 4
      t.string :synced_title
      t.datetime :dismissed_at
      t.timestamps
    end

    add_index :monobank_jar_goal_links, %i[family_id jar_id], unique: true
  end
end
