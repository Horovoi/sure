# Runs a family's rules in order through Rule::Runner. It serves the post-sync run
# (Family::Syncer), "Apply all" and "Apply rule" on the rules page.
#
# rule_ids: nil runs every active rule. With ids, those rules run, after the active
# rules above them (see Rule::Runner).
#
# The job records each rule's outcome on a RuleRun and never re-raises: a Sidekiq
# retry would run every rule again and queue the AI jobs a second time. When another
# run holds the family's lock, nothing has run yet, so the job reschedules itself.
class ApplyRulesJob < ApplicationJob
  queue_as :medium_priority

  BUSY_RETRY_DELAY = 30.seconds

  def perform(family, rule_ids: nil, execution_type: "scheduled", ignore_attribute_locks: false)
    rules = rule_ids.nil? ? family.rules.where(active: true) : family.rules.where(id: rule_ids)

    Rule::Runner.new(
      family,
      rules: rules,
      execution_type: execution_type,
      ignore_attribute_locks: ignore_attribute_locks
    ).run
  rescue Rule::Runner::LockBusy
    Rails.logger.info("ApplyRulesJob: rules are already running for family #{family.id}, retrying in #{BUSY_RETRY_DELAY.inspect}")
    self.class.set(wait: BUSY_RETRY_DELAY).perform_later(
      family, rule_ids: rule_ids, execution_type: execution_type, ignore_attribute_locks: ignore_attribute_locks
    )
    []
  rescue => e
    # The runner records rule failures itself; this is a failure around it (e.g. the
    # rules could not be loaded). Logged, not raised, for the reason above.
    Rails.logger.error("ApplyRulesJob failed for family #{family.id}: #{e.class}: #{e.message}")
    []
  end
end
