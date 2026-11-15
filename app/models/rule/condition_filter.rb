class Rule::ConditionFilter
  UnsupportedOperatorError = Class.new(StandardError)

  TYPES = [ "text", "number", "select" ]

  # Operators whose value is a pattern, not text. The pattern is bound as given
  # and matched against the column as stored: collapsing whitespace on either
  # side would change what it matches (a run of spaces, a tab, `^\s`).
  REGEX_OPERATORS = [ "matches_regex" ].freeze

  # Operators that take no value (the form hides the value field for them)
  VALUELESS_OPERATORS = [ "is_null", "is_not_null" ].freeze

  # [label key under rules.condition_filters.operators, operator]
  OPERATORS_MAP = {
    "text" => [
      [ :contains, "like" ],
      [ :does_not_contain, "not_like" ],
      [ :starts_with, "starts_with" ],
      [ :ends_with, "ends_with" ],
      [ :matches_regex, "matches_regex" ],
      [ :equal_to, "=" ],
      [ :not_equal_to, "!=" ],
      [ :is_empty, "is_null" ],
      [ :is_not_empty, "is_not_null" ]
    ],
    "number" => [
      [ :greater_than, ">" ],
      [ :greater_or_equal_to, ">=" ],
      [ :less_than, "<" ],
      [ :less_than_or_equal_to, "<=" ],
      [ :is_equal_to, "=" ],
      [ :not_equal_to, "!=" ]
    ],
    "select" => [
      [ :equal_to, "=" ],
      [ :not_equal_to, "!=" ],
      [ :is_empty, "is_null" ],
      [ :is_not_empty, "is_not_null" ]
    ]
  }.freeze

  def initialize(rule)
    @rule = rule
  end

  def type
    "text"
  end

  def number_step
    family_currency = Money::Currency.new(family.currency)
    family_currency.step
  end

  def self.key
    name.demodulize.underscore
  end

  def key
    self.class.key
  end

  def label
    key.humanize
  end

  def options
    nil
  end

  # [[label, operator], ...] for the operator select
  def operators
    OPERATORS_MAP.fetch(type).map { |label_key, operator| [ operator_label(label_key), operator ] }
  end

  # Matchers can prepare the scope with joins by implementing this method
  def prepare(scope)
    scope
  end

  # Applies the condition to the scope
  def apply(scope, operator, value)
    raise NotImplementedError, "Condition #{self.class.name} must implement #apply"
  end

  def as_json
    {
      type: type,
      key: key,
      label: label,
      operators: operators,
      options: options,
      number_step: number_step
    }
  end

  private
    attr_reader :rule

    def family
      rule.family
    end

    def operator_label(label_key)
      I18n.t("rules.condition_filters.operators.#{label_key}")
    end

    def build_sanitized_where_condition(field, operator, value)
      sql_operator = sanitize_operator(operator)

      return "#{field} #{sql_operator}" if VALUELESS_OPERATORS.include?(operator)

      regex = REGEX_OPERATORS.include?(operator)
      normalized_value = regex ? value.to_s : normalize_value(value)
      normalized_field = regex ? field : normalize_field(field)

      case operator
      when "starts_with", "ends_with"
        like_value = ActiveRecord::Base.sanitize_sql_like(normalized_value)
        like_value = operator == "starts_with" ? "#{like_value}%" : "%#{like_value}"

        ActiveRecord::Base.sanitize_sql_for_conditions([ "#{normalized_field} ILIKE ?", like_value ])
      when "like", "not_like"
        like_value = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_value)}%"
        expression = ActiveRecord::Base.sanitize_sql_for_conditions([ "#{normalized_field} #{sql_operator} ?", like_value ])

        # "Does not contain" also matches rows where the field is absent (NULL):
        # NOT ILIKE alone drops them through SQL's three-valued logic.
        operator == "not_like" ? "(#{expression} OR #{field} IS NULL)" : expression
      else
        ActiveRecord::Base.sanitize_sql_for_conditions([ "#{normalized_field} #{sql_operator} ?", normalized_value ])
      end
    end

    def sanitize_operator(operator)
      raise UnsupportedOperatorError, "Unsupported operator: #{operator} for type: #{type}" unless operators.map(&:last).include?(operator)

      case operator
      when "like"
        "ILIKE"
      when "not_like"
        "NOT ILIKE"
      when "starts_with", "ends_with"
        "ILIKE"
      when "matches_regex"
        # Case-insensitive POSIX match, run by Postgres (see Rule::SafeRegex)
        "~*"
      when "is_null"
        "IS NULL"
      when "is_not_null"
        "IS NOT NULL"
      when "!="
        # IS DISTINCT FROM treats NULL as a value, so "category not equal to X" also
        # matches uncategorized transactions. Amounts are never NULL, so numbers
        # behave as with a plain !=.
        "IS DISTINCT FROM"
      else
        operator
      end
    end

    def normalize_value(value)
      return value unless type == "text"

      # Collapse whitespace the way normalize_field does on the SQL side
      value.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    def normalize_field(field)
      return field unless type == "text"

      "BTRIM(REGEXP_REPLACE(#{field}, '[[:space:]]+', ' ', 'g'))"
    end
end
