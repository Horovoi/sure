# Activates a rule and runs it on the transactions it matches now, like Apply on the rules page, but in the call
# itself through Rule::Runner, so the result names the RuleRun and the transactions that changed. Hand port of
# upstream ec5cbd901 on the fork's ordered runner and RuleRun state machine.
#
# It needs the preview_token of a preview of the rule as it is now (RuleSupport), so a skipped, stale or edited
# preview cannot be applied. The audit keeps the rule and the matches' fields from before the run, and names the
# RuleRun rows it wrote.
class Assistant::Function::ApplyRule < Assistant::Function
  include Assistant::Function::RuleSupport

  # Matches whose fields the audit snapshot keeps; the snapshot is capped at AiToolAudit::MAX_JSON_BYTES anyway
  MAX_SNAPSHOT_TRANSACTIONS = 200

  scope_tag :destructive

  class << self
    def name
      "apply_rule"
    end

    def description
      <<~INSTRUCTIONS
        Activates a rule and runs it now on the transactions it matches. Once
        active, it also runs after every sync. update_rule active: false stops
        future runs; the changes this run makes stay.

        preview_token must come from the latest preview_rule, create_rule or
        update_rule of this rule (get_rules does not issue one). It expires
        after #{Assistant::Function::RuleSupport::PREVIEW_TOKEN_TTL.inspect}. If the rule or its matches changed
        since, nothing is applied and the result has a fresh preview with a new
        token.

        Active rules higher up in the list run first, as on the rules page, so
        a field one of them sets is left alone. By default values that an
        import or an AI set and locked are kept; override_locked: true replaces
        those too. Values the user set by hand are never replaced.

        Returns rule_run_id and the ids of the transactions that changed.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[rule_id preview_token],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule id from get_rules or create_rule."
        },
        preview_token: {
          type: "string",
          description: "preview_token from the latest preview of this rule."
        },
        override_locked: {
          type: "boolean",
          description: "Also replace values an import or an AI set and locked (default false). Values set by hand are always kept."
        }
      }
    )
  end

  def record_type
    "RuleRun"
  end

  # The RuleRun rows this call wrote, its own first; the changed transactions are in the result
  def audit_refs(result)
    return [] unless result.is_a?(Hash)

    [ result[:rule_run_id], *Array(result[:other_rule_run_ids]) ].compact.map(&:to_s).uniq
  end

  # The rule, and the fields a rule action can change on each match, so a wrong run can be undone by hand
  def audit_before(params)
    rule = find_rule(params["rule_id"])
    return nil unless rule

    ids = rule.matching_scope.limit(MAX_SNAPSHOT_TRANSACTIONS + 1).pluck(:id)
    {
      rule: serialize_rule(rule),
      transactions: rule_fields_by_transaction(ids.first(MAX_SNAPSHOT_TRANSACTIONS)).values,
      transactions_truncated: ids.size > MAX_SNAPSHOT_TRANSACTIONS
    }
  rescue Rule::SafeRegex::TimeoutError
    rule && { rule: serialize_rule(rule) }
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return rule_not_found unless rule

    if ai_action?(rule)
      return tool_error("ai_action", "This rule has an AI-backed action; it is applied in Settings > Rules, which shows the cost estimate first.")
    end

    token = read_preview_token(params["preview_token"], rule)
    unless token
      return tool_error(
        "preview_required",
        "Call preview_rule with this rule_id and pass its preview_token. Tokens expire after #{PREVIEW_TOKEN_TTL.inspect}."
      )
    end

    override_locked = ActiveModel::Type::Boolean.new.cast(params["override_locked"]) || false

    current = nil
    unchanged = false
    before = {}
    rule.with_lock do
      matched_ids = rule.matching_scope.pluck(:id)
      current = matched_ids.size
      unchanged = definition_digest(rule) == token["definition"] && current == token["match_count"]
      next unless unchanged

      before = rule_fields_by_transaction(matched_ids)
      rule.update!(active: true)
    end

    unless unchanged
      preview, error = preview_or_error(rule, sample_size: DEFAULT_SAMPLE_SIZE)
      return error if error

      return tool_error(
        "preview_stale",
        "The rule or its matches changed since that preview (it now matches #{current} transactions). Nothing was applied; " \
        "check this preview and retry with its preview_token.",
        rule: serialize_rule(rule),
        preview: preview
      )
    end

    run_now(rule, before, override_locked: override_locked)
  rescue Rule::SafeRegex::TimeoutError
    tool_error("pattern_timeout", "A matches_regex pattern took too long to run. Use a simpler pattern or a contains condition.")
  end

  private
    def run_now(rule, before, override_locked:)
      runner = Rule::Runner.new(family, rules: [ rule ], execution_type: "manual", ignore_attribute_locks: override_locked)
      rule_runs = runner.run
      own_run = rule_runs.find { |run| run.rule_id == rule.id }

      matched_ids = Array(runner.matched_ids[rule.id])
      after = rule_fields_by_transaction((matched_ids + before.keys).uniq)
      changed_ids = after.keys.select { |id| after[id] != before[id] }

      {
        id: rule.id,
        rule: serialize_rule(rule.reload),
        rule_run_id: own_run&.id,
        rule_run: own_run && serialize_rule_run(own_run.reload),
        other_rule_run_ids: (rule_runs - [ own_run ]).map(&:id),
        matched_count: matched_ids.size,
        changed_count: changed_ids.size,
        ids: changed_ids,
        override_locked: override_locked,
        message: "Rule activated and run on #{matched_ids.size} transactions; #{changed_ids.size} changed. It also runs after every sync."
      }
    rescue Rule::Runner::LockBusy
      # Another run of the family's rules holds the lock. The rule is active; the job retries until the lock is free.
      rule.apply_later(ignore_attribute_locks: override_locked)

      {
        id: rule.id,
        rule: serialize_rule(rule.reload),
        queued: true,
        override_locked: override_locked,
        message: "Rule activated. Other rules are running now, so this one is queued; get_rules with rule_id shows its run later."
      }
    end
end
