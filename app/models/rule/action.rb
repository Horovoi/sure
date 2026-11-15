class Rule::Action < ApplicationRecord
  belongs_to :rule, touch: true

  # Every action type the registry knows, offered right now or not: a saved AI
  # action stays valid while no LLM provider is configured.
  SUPPORTED_ACTION_TYPES = Rule::Registry::TransactionResource.action_executor_keys.freeze

  # A null byte or malformed UTF-8 is reported by DatabaseTextValidator instead.
  validates :action_type, presence: true, inclusion: { in: SUPPORTED_ACTION_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(action_type) }
  validates_with DatabaseTextValidator, attributes: %i[action_type value]

  # Accepts an Array (the multi-select tag picker) and stores it comma-separated
  # in the existing `value` column, so multi-value actions need no schema change.
  # A single id round-trips unchanged, so a stored single-tag action still reads.
  def value=(val)
    if val.is_a?(Array)
      val = val.reject do |item|
        # blank? raises on malformed UTF-8; DatabaseTextValidator reports such an item
        next false if item.is_a?(String) && !item.valid_encoding?

        item.blank?
      end.uniq.join(",")
    end

    super(val)
  end

  # Encodes names (of tags) as one comma-separated string for the portable export
  # and the rule CSV import, quoting a name that holds a comma ("Food, Dining") so
  # it comes back as one name. A single plain name is written unchanged.
  def self.encode_multi_value_names(names)
    CSV.generate_line(Array(names), row_sep: "")
  end

  # Inverse of .encode_multi_value_names. Also reads the plain unquoted form, and a
  # name with a stray quote that is not valid CSV comes back whole.
  def self.decode_multi_value_names(string)
    return Array(string).map(&:to_s) if string.is_a?(Array)

    CSV.parse_line(string.to_s, liberal_parsing: true) || []
  rescue CSV::MalformedCSVError
    [ string.to_s ]
  end

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: execution_value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  # The value as the executor and the form read it: a list of ids for a
  # multi-select action, the stored string otherwise
  def execution_value
    executor.type == "multi_select" ? value.to_s.split(",").compact_blank : value
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

  # The option labels of the stored value, joined for a multi-select action. The
  # options are read once, not once per selected id.
  def value_display
    return "" if value.blank?

    cached_options = options
    return "" if cached_options.blank?

    labels_by_id = cached_options.to_h { |label, id| [ id.to_s, label ] }
    Array(execution_value).filter_map { |id| labels_by_id[id.to_s] }.join(", ")
  end

  def executor
    rule.registry.get_executor!(action_type)
  end
end
