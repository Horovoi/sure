# Links a goal to an account that funds it. allocated_amount nil means the goal uses
# the whole account balance; a number earmarks a fixed slice, in the account's currency.
# The share that actually counts (after other goals' earmarks and the pro-rata cut when
# the earmarks exceed the balance) is Goal#current_balance's job.
class GoalAccount < ApplicationRecord
  belongs_to :goal
  belongs_to :account

  validates :account_id, uniqueness: { scope: :goal_id }
  validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  validate :whole_account_link_must_be_exclusive

  def whole_account?
    allocated_amount.nil?
  end

  private
    # Two whole-account links on one account would both read the full balance: the
    # pro-rata cut scales only fixed earmarks, so it cannot catch this. It is refused
    # when the link is written instead. Goals in Goal::RELEASED_STATES have handed their
    # money back and do not block (Goal#whole_account_conflicts_on).
    #
    # Only links written now are checked (new, re-priced or moved), so a goal that holds
    # an older overlap can still be renamed: autosave revalidates every loaded link.
    def whole_account_link_must_be_exclusive
      return unless whole_account?
      return if account_id.nil? || goal.nil?
      return unless new_record? ||
                    will_save_change_to_allocated_amount? ||
                    will_save_change_to_account_id? ||
                    will_save_change_to_goal_id?

      other = goal.whole_account_conflicts_on(account_id, excluding_link_id: id).first
      return if other.nil?

      errors.add(:base, :account_already_fully_earmarked, goal_name: other.goal.name)
    end
end
