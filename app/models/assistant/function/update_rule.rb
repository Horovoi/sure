# Renames a rule, replaces its definition, or deactivates it. Changing what an active rule matches or does
# deactivates it, so the new version runs only after apply_rule with a fresh preview_token, which this call returns.
# The audit keeps the rule as it was. Hand port of upstream ec5cbd901.
class Assistant::Function::UpdateRule < Assistant::Function
  include Assistant::Function::RuleSupport

  scope_tag :write

  class << self
    def name
      "update_rule"
    end

    def description
      <<~INSTRUCTIONS
        Updates a transaction rule from get_rules. Any of:
        - name: rename it (an active rule stays active).
        - conditions / actions: replace that whole list (send every item, not
          only the changed one). effective_date: change it, or "" to clear it.
          Any of these deactivates the rule; apply_rule with the returned
          preview_token activates the new version.
        - active: false stops the rule from running after syncs. It cannot
          activate a rule; apply_rule does that.

        Rules with AI-backed actions (auto categorize, auto detect merchants)
        are edited in Settings > Rules.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[rule_id],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule id from get_rules."
        },
        name: {
          type: "string",
          description: "New name. Pass \"\" to clear it."
        },
        **definition_properties,
        active: {
          type: "boolean",
          description: "Only false is accepted: deactivates the rule."
        },
        sample_size: sample_size_property
      }
    )
  end

  def record_type
    "Rule"
  end

  def audit_before(params)
    rule = find_rule(params["rule_id"])
    rule && serialize_rule(rule)
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return rule_not_found unless rule

    active = params.key?("active") ? ActiveModel::Type::Boolean.new.cast(params["active"]) : nil
    return tool_error("cannot_activate", "update_rule cannot activate a rule. Call apply_rule with the preview_token of a preview.") if active == true

    definition = params.slice("conditions", "actions", "effective_date")
    if definition.empty? && !params.key?("name") && active.nil?
      return tool_error("no_changes", "Pass at least one of name, conditions, actions, effective_date or active: false.")
    end

    if ai_action?(rule) && definition.any?
      return tool_error("ai_action", "This rule has an AI-backed action; its definition is edited in Settings > Rules.")
    end

    was_active = rule.active
    rule.name = params["name"].to_s.strip.presence if params.key?("name")
    rule.active = false if active == false || definition.any?

    problems = assign_definition(rule, definition)
    problems = validate_rule(rule) if problems.empty?
    return tool_error("invalid_rule", "The rule was not updated. Fix the listed problems and retry once.", problems: problems) if problems.any?

    rule.save!
    rule = find_rule(rule.id)

    preview, error = preview_or_error(rule, sample_size: resolved_sample_size(params))

    message =
      if was_active && !rule.active
        "Rule updated and deactivated. Pass the preview_token to apply_rule to activate it again."
      else
        "Rule updated."
      end

    {
      id: rule.id,
      rule: serialize_rule(rule),
      preview: preview,
      preview_error: error,
      message: message
    }.compact
  end
end
