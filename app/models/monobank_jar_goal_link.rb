# What the monobank sync remembers about the Sure goal made from one jar's savings target
# (MonobankAccount::JarGoal). Kept per family and jar (monobank's jar id, the same across
# tokens), so a jar that is disconnected and connected again finds its goal again, and a
# goal the owner deleted stays deleted.
class MonobankJarGoalLink < ApplicationRecord
  belongs_to :family
  # Deleting the goal clears it (Goal#release_monobank_jar_goal_links, and the foreign key)
  belongs_to :goal, optional: true
  # The account the sync put the goal's whole-account link on
  belongs_to :funding_account, class_name: "Account", optional: true

  validates :jar_id, presence: true, uniqueness: { scope: :family_id }

  # A goal was made once (the synced target is set only then) and is gone now: the owner
  # deleted it. goal_dismissed_at is set by Goal#destroy; the synced target covers a goal
  # deleted without callbacks, which only the foreign key saw.
  def dismissed?
    goal_id.nil? && (dismissed_at.present? || synced_target.present?)
  end
end
