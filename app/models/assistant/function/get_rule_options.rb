# The condition types, operators and action types a rule can use, so the model builds a valid definition for
# preview_rule and create_rule without guessing. Id-valued fields point at the tool that lists the ids instead of
# inlining every account, category, tag and merchant. Hand port of upstream ec5cbd901 on the fork's operators.
class Assistant::Function::GetRuleOptions < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "get_rule_options"
    end

    def description
      <<~INSTRUCTIONS
        Returns what a transaction rule can contain: each condition type with
        its operators and value format, and each action type with its value
        format. Call it before preview_rule or create_rule.

        Text conditions ignore case and repeated spaces; "like" means contains,
        and matches_regex takes a case-insensitive POSIX pattern. Amount
        conditions compare the absolute amount. Actions that call an AI model
        (auto categorize, auto detect merchants) are not available here.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema
  end

  def call(_params = {})
    rule = family.rules.build(resource_type: "transaction")

    {
      conditions: rule.condition_filters.map { |filter| describe_filter(rule, filter) } + [ compound_option ],
      actions: rule.action_executors.reject { |e| BLOCKED_ACTION_TYPES.include?(e.key) }.map { |executor| describe_executor(rule, executor) }
    }
  end

  private
    def describe_filter(rule, filter)
      {
        condition_type: filter.key,
        label: filter.label,
        value_type: filter.type,
        operators: filter.operators.map { |label, value| { value: value, label: label } },
        values: value_spec(rule, filter.key)
      }.compact
    end

    def compound_option
      {
        condition_type: "compound",
        label: "Group of conditions",
        operators: [ { value: "and", label: "all match" }, { value: "or", label: "any matches" } ],
        values: "sub_conditions: an array of plain conditions (one level, no nesting)"
      }
    end

    def describe_executor(rule, executor)
      {
        action_type: executor.key,
        label: executor.label,
        value_type: executor.type,
        values: executor.type == "function" ? nil : value_spec(rule, executor.key)
      }.compact
    end

    def value_spec(rule, key)
      case key
      when *ACCOUNT_KEYS then "account id from get_accounts"
      when *CATEGORY_KEYS then "category id from get_categories"
      when "transaction_tag" then "tag id from get_tags"
      when "set_transaction_tags" then "array of tag ids from get_tags"
      when *MERCHANT_KEYS then "merchant id from get_merchants"
      when "transaction_type", "set_investment_activity_label" then allowed_values(rule, key)
      when "transaction_amount" then "number (absolute amount, in the account's currency)"
      when "set_transaction_name" then "the new transaction name"
      else "text"
      end
    end
end
