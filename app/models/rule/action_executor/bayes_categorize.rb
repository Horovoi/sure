# The local Bayes classifier as a rule action: categorizes the uncategorized
# matches it is sure of, in the rule's place in the order. It runs on this machine
# and costs nothing, so it is offered without an AI provider.
#
# It claims category_id like the other category actions, so it leaves alone what a
# rule above set, but reserves nothing: its guess carries a soft lock and the rules
# below may still set the category (see Rule::Runner).
class Rule::ActionExecutor::BayesCategorize < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.bayes_categorize")
  end

  def claimed_attributes
    [ :category_id ]
  end

  def reserves_claimed_attributes?
    false
  end

  # Only uncategorized transactions are candidates, so ignore_attribute_locks has
  # nothing to replace here
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    family.bayes_categorize(transaction_scope)
  end
end
