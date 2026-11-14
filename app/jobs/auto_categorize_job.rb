class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    RuleRun.report_job(rule_run_id, self.class.name) { family.auto_categorize_transactions(transaction_ids) }
  end
end
