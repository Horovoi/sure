class Rule::Action < ApplicationRecord
  belongs_to :rule, touch: true

  # Every action type the registry knows, offered right now or not: a saved AI
  # action stays valid while no LLM provider is configured.
  SUPPORTED_ACTION_TYPES = Rule::Registry::TransactionResource.action_executor_keys.freeze

  # A null byte or malformed UTF-8 is reported by DatabaseTextValidator instead.
  validates :action_type, presence: true, inclusion: { in: SUPPORTED_ACTION_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(action_type) }
  validates_with DatabaseTextValidator, attributes: %i[action_type value]

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  def options
    rule.option_list([ :action, action_type ]) { executor.options }
  end

  def claimed_attributes
    executor.claimed_attributes
  end

  # Whether this action keeps the rules below it from setting its claimed attributes
  # on the transactions it matched (see Rule::Runner)
  def reserves_claimed_attributes?
    executor.reserves_claimed_attributes? && executor.actionable?(value)
  end

  def value_display
    if value.present?
      if options
        options.find { |option| option.last == value }&.first
      else
        ""
      end
    else
      ""
    end
  end

  def executor
    rule.registry.get_executor!(action_type)
  end
end
