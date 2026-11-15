# Shows what a rule matches without changing anything, for a saved rule or an unsaved definition. For a saved rule
# it also issues the preview_token apply_rule requires. Hand port of upstream ec5cbd901.
class Assistant::Function::PreviewRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "preview_rule"
    end

    def description
      <<~INSTRUCTIONS
        Shows which transactions a rule matches, without changing anything.
        Pass either rule_id (a saved rule) or an unsaved definition
        (conditions, actions, optional effective_date); get_rule_options lists
        the valid values.

        Returns match_count (every matching transaction, which is what the
        rule would touch), a sample of the most recent matches with their
        current category and merchant, and the actions in readable form. A
        loose condition ("greater than" instead of "equal to") rewrites far
        more transactions than intended, so check the sample against what the
        rule is meant to do.

        For a saved rule it also returns preview_token, which apply_rule needs.
        No token is issued when there are matches but none is listed
        (sample_size 0).
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        rule_id: {
          type: "string",
          description: "A saved rule from get_rules. Omit when passing a definition."
        },
        **definition_properties,
        sample_size: sample_size_property
      }
    )
  end

  def call(params = {})
    definition_given = params.key?("conditions") || params.key?("actions")

    if params["rule_id"].present?
      return tool_error("invalid_arguments", "Pass either rule_id or a definition, not both.") if definition_given

      rule = find_rule(params["rule_id"])
      return rule_not_found unless rule
    else
      return tool_error("invalid_arguments", "Pass rule_id, or a definition with conditions and actions.") unless definition_given

      rule = family.rules.build(resource_type: "transaction", active: false)
      problems = assign_definition(rule, params.slice("conditions", "actions", "effective_date"))
      problems = validate_rule(rule) if problems.empty?
      return tool_error("invalid_rule", "Fix the listed problems and retry once.", problems: problems) if problems.any?
    end

    preview, error = preview_or_error(rule, sample_size: resolved_sample_size(params))
    return error if error

    { rule: serialize_rule(rule), preview: preview }
  end
end
