# Applies one rule, after the active rules above it (see Rule::Runner). A thin
# wrapper around ApplyRulesJob, kept so jobs queued before the ordered runner still
# run. New code calls Rule#apply_later.
class RuleJob < ApplicationJob
  queue_as :medium_priority

  def perform(rule, ignore_attribute_locks: false, execution_type: "manual")
    ApplyRulesJob.perform_now(rule.family, rule_ids: [ rule.id ], ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
  end
end
