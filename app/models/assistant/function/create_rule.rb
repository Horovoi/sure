# Saves a new transaction rule, always inactive, at the bottom of the run order. Nothing changes until apply_rule
# activates it with the preview_token this call returns, so a rule cannot start rewriting transactions (or run after
# every sync) from a single call. Hand port of upstream ec5cbd901.
class Assistant::Function::CreateRule < Assistant::Function
  include Assistant::Function::RuleSupport

  scope_tag :write

  class << self
    def name
      "create_rule"
    end

    def description
      <<~INSTRUCTIONS
        Saves a new transaction rule at the bottom of the rule list. The rule
        is saved inactive: it changes no transaction until apply_rule activates
        it.

        Build the definition from get_rule_options. The result has the saved
        rule and the same preview as preview_rule (match_count, a sample of the
        matches, the actions); pass its preview_token to apply_rule to activate
        the rule and run it on the matches.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[conditions actions],
      properties: {
        name: {
          type: "string",
          description: "Optional rule name shown in Settings > Rules."
        },
        **definition_properties,
        sample_size: sample_size_property
      }
    )
  end

  def record_type
    "Rule"
  end

  def call(params = {})
    unless params.key?("conditions") && params.key?("actions")
      return tool_error("invalid_arguments", "Pass both conditions and actions; get_rule_options lists the valid values.")
    end

    rule = family.rules.build(resource_type: "transaction", active: false, name: params["name"].to_s.strip.presence)
    problems = assign_definition(rule, params.slice("conditions", "actions", "effective_date"))
    problems = validate_rule(rule) if problems.empty?
    return tool_error("invalid_rule", "The rule was not saved. Fix the listed problems and retry once.", problems: problems) if problems.any?

    rule.save!
    rule = find_rule(rule.id)

    preview, error = preview_or_error(rule, sample_size: resolved_sample_size(params))

    {
      id: rule.id,
      rule: serialize_rule(rule),
      preview: preview,
      preview_error: error,
      message: "Rule saved inactive. Pass the preview_token to apply_rule to activate it."
    }.compact
  end
end
