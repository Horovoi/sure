class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?

    begin
      modified_count = family.auto_categorize_transactions(transaction_ids)
    rescue => e
      # Outside a rule run, let Sidekiq retry as usual.
      raise unless rule_run

      # Inside a rule run, record the failure on the run instead of retrying:
      # a retry would call the LLM again for a run that is already reported.
      Rails.logger.error("AutoCategorizeJob failed for rule run #{rule_run.id}: #{e.class}: #{e.message}")
      rule_run.fail_job!(e)
      return
    end

    rule_run&.complete_job!(modified_count: modified_count)
  end
end
