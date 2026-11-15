class Assistant::Function
  class << self
    def name
      raise NotImplementedError, "Subclasses must implement the name class method"
    end

    def description
      raise NotImplementedError, "Subclasses must implement the description class method"
    end
  end

  # Largest page a paginated tool returns, whatever page_size asks for
  MAX_PAGE_SIZE = 100

  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def initialize(user)
    @user = user
  end

  def call(params = {})
    raise NotImplementedError, "Subclasses must implement the call method"
  end

  def name
    self.class.name
  end

  def description
    self.class.description
  end

  def params_schema
    build_schema
  end

  # (preferred) when in strict mode, the schema needs to include all properties in required array
  def strict_mode?
    true
  end

  def to_definition
    {
      name: name,
      description: description,
      params_schema: params_schema,
      strict: strict_mode?
    }
  end

  # Human-readable name MCP clients show for the tool
  def title
    name.to_s.humanize
  end

  # MCP tool annotations, as keywords of MCP::Tool::Annotations. The default fits a tool that only reads
  # Sure's own data. A tool that changes records or reaches outside Sure overrides this. Clients treat the hints
  # as advice for how to present a call; they never gate one.
  def mcp_annotations
    {
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    }
  end

  # The input schema served over MCP. MCP validates arguments against it, so a property whose type allows null
  # is optional there (a client may leave it out instead of sending null), and empty enums are pruned.
  def mcp_input_schema
    schema = params_schema.deep_dup.deep_symbolize_keys
    properties = schema[:properties] || {}
    nullable = properties.select { |_key, property| nullable_property?(property) }.keys.map(&:to_s)
    schema[:required] = Array(schema[:required]).map(&:to_s) - nullable

    prune_empty_enums(schema)
  end

  private
    attr_reader :user

    def build_schema(properties: {}, required: [])
      {
        type: "object",
        properties: prune_empty_enums(properties),
        required: required,
        additionalProperties: false
      }
    end

    # Enum values are built from family data (account names, categories, merchants, tags, tickers) and are empty
    # for a family that has none. An empty enum is invalid JSON Schema, which strict providers and MCP clients
    # reject, so the constraint is dropped and the node falls back to a plain string.
    def prune_empty_enums(node)
      case node
      when Hash
        dropped_enum = false

        pruned = node.each_with_object({}) do |(key, value), result|
          # Enum members are literal values, not subschemas, so they are kept verbatim
          if key.to_sym == :enum && value.is_a?(Array) && value.empty?
            dropped_enum = true
          elsif key.to_sym == :enum && value.is_a?(Array)
            result[key] = value
          else
            result[key] = prune_empty_enums(value)
          end
        end

        pruned[:type] = "string" if dropped_enum && !pruned.key?(:type) && !pruned.key?("type")
        pruned
      when Array
        node.map { |item| prune_empty_enums(item) }
      else
        node
      end
    end

    def nullable_property?(property)
      return false unless property.is_a?(Hash)

      Array(property[:type]).map(&:to_s).include?("null") ||
        Array(property[:anyOf]).any? { |option| option.is_a?(Hash) && option[:type].to_s == "null" }
    end

    # Tag lists are small, so a tool that names tags may still offer them as an enum. The large data-driven enums
    # (accounts, categories, merchants) are gone from schemas: they grew with family data and changed the tool
    # definitions whenever a name did. Filters take exact names from the sibling get_* tools instead.
    def family_tag_names
      @family_tag_names ||= family.tags.pluck(:name)
    end

    # Page size for a paginated tool that declares a page_size param, clamped to 1..MAX_PAGE_SIZE
    def resolved_page_size(params)
      return self.class.default_page_size if params["page_size"].blank?

      params["page_size"].to_i.clamp(1, MAX_PAGE_SIZE)
    end

    # Pagy refuses zero, negative or non-numeric pages; anything invalid reads as the first page. A page past the
    # end gives the last page (Paginatable).
    def resolved_page(params)
      page = params["page"].to_i
      page.positive? ? page : 1
    end

    # A soft failure the model can act on, in the same {error, hint} shape FunctionToolCaller gives a raised error:
    # a short code, what to change, and any extra keys that help (e.g. the ids that were not found).
    def tool_error(code, hint, **details)
      { error: code, hint: hint, **details }
    end

    def valid_uuid?(value)
      value.is_a?(String) && UUID_FORMAT.match?(value)
    end

    # Period.from_key reads Current.family for the fiscal month and "all time", and the chat job has no Current.
    # Those two keys are built from the tool's own family instead, so the chat and /mcp agree.
    def named_period(key)
      case key
      when "fiscal_current_month"
        Period.custom(start_date: family.budget_period_start_for(Date.current), end_date: Date.current)
      when "all_time"
        start_date = family.oldest_entry_date
        start_date = 5.years.ago.to_date if start_date >= Date.current
        Period.custom(start_date: start_date, end_date: Date.current)
      else
        Period.from_key(key)
      end
    end

    def family
      user.family
    end

    # To save tokens, the series is metadata plus a flat array of numbers the model can infer dates from. The
    # currency is stated once instead of formatting every value, and values round to the currency's own precision
    # (UAH and USD 2, BTC 8), rounded as BigDecimal before the Float conversion.
    def to_ai_time_series(series)
      currency = series.values.first&.trend&.current&.currency
      precision = currency&.default_precision || 2

      {
        start_date: series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        currency: currency&.iso_code,
        values: series.values.map { |v| v.trend.current.amount.round(precision).to_f }
      }.compact
    end
end
