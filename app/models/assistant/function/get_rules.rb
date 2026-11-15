# Lists the family's transaction rules in run order, in readable form: each condition and action with its ids
# resolved to names, whether the rule is active, and its latest run. Hand port of upstream ec5cbd901.
class Assistant::Function::GetRules < Assistant::Function
  include Assistant::Function::RuleSupport
  include Paginatable

  class << self
    def default_page_size
      50
    end

    def name
      "get_rules"
    end

    def description
      <<~INSTRUCTIONS
        Lists the family's transaction rules in the order they run (position):
        conditions, actions (with account, category, tag and merchant names),
        whether each rule is active, stop_processing, effective_date, and the
        latest run with its RuleRun id.

        Active rules run again after every sync, top to bottom: for a field
        that several rules set, the rule higher up wins. Pass rule_id for one
        rule, which also includes how many transactions it matches now.

        Use search to check whether a rule already exists: it matches the rule
        name, condition values (a payee in a "name contains" condition, for
        example), action values, and the names of categories the rule sets.

        Results are paginated (page_size defaults to #{default_page_size}); the
        response includes total_results, page, page_size and total_pages.
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
          description: "Optional. Return only this rule, with its current match count."
        },
        active: {
          type: "boolean",
          description: "Optional. true for active rules only, false for inactive ones only."
        },
        search: {
          type: "string",
          description: "Optional. Case-insensitive text to find in the rule name, condition and action values, or the name of a category it sets."
        },
        page: {
          type: "integer",
          minimum: 1,
          description: "Page number (defaults to 1)"
        },
        page_size: {
          type: "integer",
          minimum: 1,
          maximum: MAX_PAGE_SIZE,
          description: "Results per page (defaults to #{self.class.default_page_size})"
        }
      }
    )
  end

  def call(params = {})
    if params["rule_id"].present?
      rule = find_rule(params["rule_id"])
      return rule_not_found unless rule

      return { rule: serialize_rule(rule, include_last_run: true).merge(match_count: rule.affected_resource_count) }
    end

    rules = family.rules
    rules = rules.where(active: ActiveModel::Type::Boolean.new.cast(params["active"])) unless params["active"].nil?
    rules = matching_search(rules, params["search"]) if params["search"].present?

    page_size = resolved_page_size(params)
    pagy, page = pagy(
      rules.includes(:actions, conditions: :sub_conditions).ordered,
      page: resolved_page(params),
      limit: page_size,
      request: { params: {} }
    )

    {
      rules: page.map { |rule| serialize_rule(rule, include_last_run: true) },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end

  private
    # Rules are often unnamed, so the search also looks inside conditions (grouped ones included), action values,
    # and the names of the categories they set
    def matching_search(rules, search)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(search.to_s.strip)}%"

      rules.where(<<~SQL.squish, pattern: pattern, family_id: family.id)
        rules.name ILIKE :pattern
        OR EXISTS (
          SELECT 1 FROM rule_conditions c
          LEFT JOIN rule_conditions p ON p.id = c.parent_id
          WHERE COALESCE(c.rule_id, p.rule_id) = rules.id AND c.value ILIKE :pattern
        )
        OR EXISTS (
          SELECT 1 FROM rule_actions a
          WHERE a.rule_id = rules.id
            AND (
              a.value ILIKE :pattern
              OR a.value IN (SELECT id::text FROM categories WHERE family_id = :family_id AND name ILIKE :pattern)
            )
        )
      SQL
    end
end
