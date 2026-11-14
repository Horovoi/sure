class RuleJob < ApplicationJob
  queue_as :medium_priority

  # When the same rule is already being applied (for example a post-sync run
  # overlapping a manual "apply"), try again after this delay.
  BUSY_RETRY_DELAY = 1.minute

  # The job records its outcome on a RuleRun and does not re-raise. A Sidekiq
  # retry would create a second RuleRun and queue the AI jobs a second time.
  def perform(rule, ignore_attribute_locks: false, execution_type: "manual")
    # The same rule never applies twice at once
    acquired = with_advisory_lock("rule_job:#{rule.id}") do
      run_rule(rule, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
    end

    unless acquired
      Rails.logger.info("RuleJob: rule #{rule.id} is already being applied, retrying in #{BUSY_RETRY_DELAY.inspect}")
      self.class.set(wait: BUSY_RETRY_DELAY).perform_later(rule, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
    end
  end

  private
    def run_rule(rule, ignore_attribute_locks:, execution_type:)
      # The run starts with one reserved job slot for this apply phase.
      # Async actions reserve one more slot per job before queuing it, and
      # the run only succeeds when every slot has been released.
      # The rule name is stored so it persists even if the rule is renamed later.
      rule_run = RuleRun.create!(
        rule: rule,
        rule_name: rule.name,
        execution_type: execution_type,
        transactions_queued: 0,
        transactions_processed: 0,
        transactions_modified: 0,
        pending_jobs_count: 1,
        executed_at: Time.current
      )

      begin
        transactions_queued = rule.affected_resource_count
        result = rule.apply(ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

        if result.is_a?(Hash) && result[:async]
          transactions_processed = result[:modified_count] || 0
          sync_modified = result[:sync_modified_count] || 0
        else
          transactions_processed = result.to_i
          sync_modified = result.to_i
        end

        rule_run.update!(transactions_queued: transactions_queued, transactions_processed: transactions_processed)
        rule_run.complete_job!(modified_count: sync_modified)
      rescue => e
        Rails.logger.error("RuleJob failed for rule #{rule.id}: #{e.class}: #{e.message}")
        rule_run.fail_job!(e)
      end

      rule_run
    end
end
