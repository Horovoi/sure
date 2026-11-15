class Rule::Condition < ApplicationRecord
  SUPPORTED_CONDITION_TYPES = (Rule::Registry::TransactionResource.condition_filter_keys + [ "compound" ]).freeze

  # Old condition types that a save maps to their current name
  LEGACY_CONDITION_TYPE_ALIASES = {
    "name" => "transaction_name"
  }.freeze

  COMPOUND_OPERATORS = %w[and or].freeze

  belongs_to :rule, touch: true, optional: -> { where.not(parent_id: nil) }
  belongs_to :parent, class_name: "Rule::Condition", optional: true, inverse_of: :sub_conditions

  has_many :sub_conditions, -> { order(:created_at, :id) }, class_name: "Rule::Condition", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent

  before_validation :normalize_legacy_condition_type

  # A null byte or malformed UTF-8 is reported by DatabaseTextValidator; the other
  # checks skip such a value, because blank? raises on malformed UTF-8.
  validates :condition_type, presence: true, inclusion: { in: SUPPORTED_CONDITION_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(condition_type) }
  validates :operator, presence: true, if: -> { DatabaseTextValidator.acceptable?(operator) }
  validates :value, presence: true,
    unless: -> { compound? || Rule::ConditionFilter::VALUELESS_OPERATORS.include?(operator) },
    if: -> { DatabaseTextValidator.acceptable?(value) }
  validates_with DatabaseTextValidator, attributes: %i[condition_type operator value]

  validate :operator_offered_by_filter
  validate :regex_value_is_safe, if: :regex_value_changed?

  accepts_nested_attributes_for :sub_conditions, allow_destroy: true

  # We don't store rule_id on sub_conditions, so "walk up" to the parent rule
  def rule
    parent&.rule || super
  end

  def compound?
    condition_type == "compound"
  end

  def regex?
    Rule::ConditionFilter::REGEX_OPERATORS.include?(operator)
  end

  # True when this condition, or one nested in it, matches a pattern
  def uses_regex?
    compound? ? sub_conditions.any?(&:regex?) : regex?
  end

  # Probing a pattern costs a database round trip, so an untouched condition (a
  # rule being switched on, say) is not probed again.
  def regex_value_changed?
    regex? && (new_record? || will_save_change_to_value? || will_save_change_to_operator?)
  end

  def apply(scope)
    if compound?
      build_compound_scope(scope)
    else
      filter.apply(scope, operator, value)
    end
  end

  def prepare(scope)
    if compound?
      sub_conditions.reduce(scope) { |s, sub| sub.prepare(s) }
    else
      filter.prepare(scope)
    end
  end

  def value_display
    if value.present?
      if options
        options.find { |option| option.last == value }&.first
      else
        value
      end
    else
      ""
    end
  end

  # The operator's label ("Starts with"), or the stored operator when the filter
  # does not offer it
  def operator_display
    operators.find { |_label, op| op == operator }&.first || operator.to_s
  end

  def options
    rule.option_list([ :condition, condition_type ]) { filter.options }
  end

  def operators
    filter.operators
  end

  # A type the registry does not know (a row saved before validation, or from an
  # old import) gets a placeholder that renders and matches nothing, so the rules
  # page does not break on it.
  def filter
    rule.registry.get_filter!(condition_type)
  rescue Rule::Registry::UnsupportedConditionError
    Rule::ConditionFilter::Unsupported.new(rule, condition_type)
  end

  private
    # An operator the filter does not offer would raise on every run of the rule
    # (Rule::ConditionFilter::UnsupportedOperatorError), so it is refused at save.
    # An unknown condition type is reported by the inclusion validation instead.
    def operator_offered_by_filter
      return if operator.blank? || !DatabaseTextValidator.acceptable?(operator)

      if compound?
        errors.add(:operator, :inclusion) unless COMPOUND_OPERATORS.include?(operator)
      elsif rule&.resource_type.in?(Rule::SUPPORTED_RESOURCE_TYPES) && SUPPORTED_CONDITION_TYPES.include?(condition_type)
        errors.add(:operator, :inclusion) unless filter.operators.any? { |_label, offered| offered == operator }
      end
    end

    # A blank value is reported by the presence validation, and one the database
    # cannot store by DatabaseTextValidator. Neither can be probed: the driver
    # refuses to send a null byte.
    def regex_value_is_safe
      return unless DatabaseTextValidator.acceptable?(value)
      return if value.blank?

      error = Rule::SafeRegex.error_for(value)
      return if error.nil?

      errors.add(:value, :"regex_#{error}", count: Rule::SafeRegex::MAX_LENGTH)
    end

    def normalize_legacy_condition_type
      return unless condition_type.is_a?(String) && DatabaseTextValidator.acceptable?(condition_type)

      normalized = LEGACY_CONDITION_TYPE_ALIASES[condition_type]
      self.condition_type = normalized if normalized
    end
    def build_compound_scope(scope)
      if operator == "or"
        combined_scope = sub_conditions
          .map { |sub| sub.apply(scope) }
          .reduce { |acc, s| acc.or(s) }

        combined_scope || scope
      else
        sub_conditions.reduce(scope) { |s, sub| sub.apply(s) }
      end
    end
end
