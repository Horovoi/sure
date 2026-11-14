# One rule for when to offer "create a rule from this category change",
# shared by every controller that changes a transaction's category.
module CategoryRulePrompt
  extend ActiveSupport::Concern

  private
    def needs_rule_notification?(transaction)
      return false if Current.user.rule_prompts_disabled

      if Current.user.rule_prompt_dismissed_at.present?
        time_since_last_rule_prompt = Time.current - Current.user.rule_prompt_dismissed_at
        return false if time_since_last_rule_prompt < 1.day
      end

      # Clearing a category is not something to make a rule from
      transaction.saved_change_to_category_id? && transaction.category_id.present? &&
        transaction.eligible_for_category_rule?
    end
end
