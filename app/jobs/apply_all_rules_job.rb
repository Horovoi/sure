class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  # Applies every active rule. Inactive rules are drafts or rules the user
  # turned off, so they are skipped, as in the post-sync run.
  # A failure in one rule is recorded on its RuleRun and does not stop the
  # others, and the job never re-raises, so a Sidekiq retry cannot replay
  # rules that already ran.
  def perform(family, execution_type: "manual")
    family.rules.where(active: true).find_each do |rule|
      RuleJob.perform_now(rule, ignore_attribute_locks: true, execution_type: execution_type)
    rescue => e
      Rails.logger.error("ApplyAllRulesJob: rule #{rule.id} failed: #{e.class}: #{e.message}")
    end
  end
end
