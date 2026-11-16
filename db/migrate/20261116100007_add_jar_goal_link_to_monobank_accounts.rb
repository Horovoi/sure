# A monobank jar with a savings target becomes a Sure goal (MonobankAccount::JarGoal).
# The jar remembers its goal and what the last sync wrote to it: the target and the title,
# so a later sync changes only what changed in monobank and keeps the owner's own edits.
# Deleting the goal clears the link; goal_dismissed_at records that the owner did it, so
# the goal is not created again.
class AddJarGoalLinkToMonobankAccounts < ActiveRecord::Migration[8.1]
  def change
    add_reference :monobank_accounts, :goal, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    add_column :monobank_accounts, :goal_synced_target, :decimal, precision: 19, scale: 4
    add_column :monobank_accounts, :goal_synced_title, :string
    add_column :monobank_accounts, :goal_dismissed_at, :datetime
  end
end
