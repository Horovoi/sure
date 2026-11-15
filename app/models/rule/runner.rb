# Runs a family's rules one after another, top to bottom (Rule#position).
#
# - Top rule wins: once a rule sets an attribute on a transaction, rules further
#   down leave that attribute alone in the same run, even when the value was
#   already set or the attribute is locked. Tags are additive and claim nothing.
# - Stop processing: a transaction matched by a rule with stop_processing is not
#   touched by any rule further down.
#
# Active rules above the ones requested run first, in order, so applying a single
# rule gives the same result as its turn in the full run (e.g. it sees a rename a
# rule above makes). Rules below the last requested rule do not run. Inactive rules
# above are skipped, because they do not run after a sync either.
# ignore_attribute_locks only applies to the requested rules.
#
# Every executed rule gets a RuleRun. A failing rule is recorded as a failed run
# and the rules below still run; #run never raises for a rule, and returns the
# RuleRun rows it wrote, so callers (the rules page, MCP, chat) can keep the ids. #matched_ids then gives the
# transactions each executed rule acted on (apply_rule reports which of them changed).
#
# One run per family at a time, guarded by a PostgreSQL advisory lock. A busy lock
# raises LockBusy before anything runs, so the calling job can reschedule itself.
class Rule::Runner
  LockBusy = Class.new(StandardError)

  attr_reader :errors, :matched_ids

  def self.advisory_lock_key(family_id)
    Digest::MD5.hexdigest("rule_runner:#{family_id}").to_i(16) % (2**62)
  end

  def initialize(family, rules:, execution_type:, ignore_attribute_locks: false)
    @family = family
    @rule_ids = rules.map(&:id).to_set
    @execution_type = execution_type
    @ignore_attribute_locks = ignore_attribute_locks
    @claimed_ids = Hash.new { |hash, attribute| hash[attribute] = Set.new }
    @stopped_ids = Set.new
    @matched_ids = {}
    @errors = []
  end

  # Returns the RuleRun records created, one per executed rule, in run order.
  def run
    return [] if rule_ids.empty?

    rule_runs = nil
    acquired = with_family_lock { rule_runs = run_rules }
    raise LockBusy, "Rules are already running for family #{family.id}" unless acquired

    rule_runs.compact
  end

  private
    attr_reader :family, :rule_ids, :execution_type, :ignore_attribute_locks, :claimed_ids, :stopped_ids

    def run_rules
      rule_runs = []
      remaining_ids = rule_ids.dup

      family.rules.ordered.includes(:family, :actions, conditions: :sub_conditions).each do |rule|
        break if remaining_ids.empty?

        if remaining_ids.delete?(rule.id)
          rule_runs << execute(rule, ignore_attribute_locks: ignore_attribute_locks)
        elsif rule.active?
          rule_runs << execute(rule, ignore_attribute_locks: false)
        end
      end

      rule_runs
    end

    def unstopped_scope(rule)
      Rule.excluding_transaction_ids(rule.matching_scope, stopped_ids)
    end

    def record_claims(rule, matched_ids)
      rule.actions.each do |action|
        reserved_attributes(action).each { |attribute| claimed_ids[attribute].merge(matched_ids) }
      end

      stopped_ids.merge(matched_ids) if rule.stop_processing?
    end

    # An action that cannot be resolved (e.g. an unknown action_type from an import)
    # sets nothing, so it claims nothing and must not abort the run.
    def reserved_attributes(action)
      return [] unless action.reserves_claimed_attributes?

      action.claimed_attributes
    rescue => e
      Rails.logger.error("Rule::Runner could not read claims of action #{action.id}: #{e.class}: #{e.message}")
      []
    end

    # The run holds one job slot for this apply phase (RuleRun#pending_jobs_count).
    # Async actions reserve one more slot per job before queuing it, and the run only
    # succeeds when every slot is released, so the stale work reaper can still fail a
    # run whose jobs were lost.
    def execute(rule, ignore_attribute_locks:)
      executed_at = Time.current
      matched_ids = []
      rule_run = nil

      begin
        scope = unstopped_scope(rule)
        matched_ids = scope.pluck(:id)
        @matched_ids[rule.id] = matched_ids

        # The rule name is stored so it persists even if the rule is renamed later
        rule_run = RuleRun.create!(
          rule: rule,
          rule_name: rule.name,
          execution_type: execution_type,
          transactions_queued: matched_ids.size,
          transactions_processed: 0,
          transactions_modified: 0,
          pending_jobs_count: 1,
          executed_at: executed_at
        )

        # Every action works on the transactions matched now, not on a scope that
        # re-checks the conditions: otherwise an action that changes a matched field
        # (e.g. the name) would hide the transactions from the actions after it,
        # while the claims below still reserve them.
        result = rule.apply(
          ignore_attribute_locks: ignore_attribute_locks,
          rule_run: rule_run,
          scope: rule.scope_for_transaction_ids(matched_ids),
          claimed_ids: claimed_ids
        )

        processed, sync_modified = run_counts(result, queued: matched_ids.size, rule: rule)
        rule_run.update!(transactions_processed: processed)
        rule_run.complete_job!(modified_count: sync_modified)
      rescue => e
        rule_run = record_failure(rule, rule_run, e, executed_at: executed_at, queued: matched_ids.size)
      ensure
        # Claims hold even when the rule failed halfway, so a rule further down never
        # overwrites what this rule may already have set.
        record_claims(rule, matched_ids)
      end

      rule_run
    end

    # [transactions_processed, modifications made synchronously]. Processed counts
    # every transaction the rule tried, so the rows a lock kept unchanged show as
    # blocked (RuleRun#transactions_blocked). Async jobs add their own modified
    # count when they release their slot.
    def run_counts(result, queued:, rule:)
      if result.is_a?(Hash) && result[:async]
        [ result[:modified_count] || 0, result[:sync_modified_count] || 0 ]
      elsif result.is_a?(Integer)
        [ queued, result ]
      else
        Rails.logger.warn("Rule::Runner: Unexpected result type from rule.apply: #{result.class} for rule #{rule.id}")
        [ 0, 0 ]
      end
    end

    def record_failure(rule, rule_run, error, executed_at:, queued:)
      errors << error
      Rails.logger.error("Rule::Runner failed for rule #{rule.id}: #{error.class}: #{error.message}")

      rule_run ||= RuleRun.create!(
        rule: rule,
        rule_name: rule.name,
        execution_type: execution_type,
        transactions_queued: queued,
        transactions_processed: 0,
        transactions_modified: 0,
        pending_jobs_count: 1,
        executed_at: executed_at
      )
      rule_run.fail_job!(error)
      rule_run
    rescue => e
      Rails.logger.error("Rule::Runner: Failed to record RuleRun for rule #{rule.id}: #{e.class}: #{e.message}")
      rule_run
    end

    # One leased connection for lock and unlock, because the unlock must run on the
    # PostgreSQL session that took the lock.
    def with_family_lock
      lock_key = self.class.advisory_lock_key(family.id)
      connection = ActiveRecord::Base.lease_connection
      acquired = connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return false unless acquired

      begin
        yield
      ensure
        connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
      true
    end
end
