class Rule::Action < ApplicationRecord
  belongs_to :rule, touch: true

  validates :action_type, presence: true

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
