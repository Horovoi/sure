module Transaction::Ruleable
  extend ActiveSupport::Concern

  # Offer the "create a rule?" prompt unless an active rule that sets this category
  # already matches this transaction. Any rule targeting the category used to hide the
  # prompt, even one whose conditions can never match this transaction.
  def eligible_for_category_rule?
    return false if category_id.blank?

    rules.where(active: true, resource_type: "transaction")
         .joins(:actions)
         .where(actions: { action_type: "set_transaction_category", value: category_id })
         .distinct
         .includes(conditions: :sub_conditions)
         .none? { |rule| rule.matches_transaction?(self) }
  end

  private
    def rules
      entry.account.family.rules
    end
end
