class LlmUsage < ApplicationRecord
  belongs_to :family

  validates :provider, :model, :operation, presence: true
  validates :prompt_tokens, :completion_tokens, :total_tokens, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :estimated_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :for_family, ->(family) { where(family: family) }
  scope :for_operation, ->(operation) { where(operation: operation) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_date_range, ->(start_date, end_date) { where(created_at: start_date..end_date) }

  # Claude turns that run on the owner's Claude subscription (through the local bridge) are recorded under this
  # provider. Their estimated_cost is the API-equivalent cost of the same tokens: shown on the usage page, but
  # never added to the spend totals, because the subscription is not billed per token.
  SUBSCRIPTION_PROVIDER = "claude_subscription".freeze

  scope :subscription, -> { where(provider: SUBSCRIPTION_PROVIDER) }
  scope :billed, -> { where.not(provider: SUBSCRIPTION_PROVIDER) }

  # Standard USD pricing per 1M tokens by provider and model, refreshed by hand with bin/update_llm_pricing
  pricing_config = YAML.load_file(Rails.root.join("config/llm_pricing.yml"), permitted_classes: [ Date ], aliases: true)

  # Last complete review of every listed model, not a provider price-change date
  PRICING_VERIFIED_ON = pricing_config.fetch("verified_on").freeze

  PRICING = pricing_config.fetch("providers").transform_values do |models|
    models.transform_values { |pricing| pricing.deep_symbolize_keys.freeze }.freeze
  end.freeze

  # Calculate cost for a model and token usage
  # Provider is automatically inferred from the model using the pricing map
  # Returns nil if pricing is not available for the model (e.g., custom/self-hosted providers)
  # @param apply_long_context_pricing [Boolean] use per-request tiers; disable for aggregate batch estimates
  # @return [Float, nil] estimated USD cost
  def self.calculate_cost(model:, prompt_tokens:, completion_tokens:, cache_creation_tokens: 0, cache_read_tokens: 0,
                          apply_long_context_pricing: true)
    return nil if model.blank?

    provider = infer_provider(model)
    pricing = find_pricing(provider, model)

    unless pricing
      Rails.logger.info("No pricing found for model: #{model} (inferred provider: #{provider})")
      return nil
    end

    # Anthropic reports cached input apart from input_tokens, but its long-context tier counts cache reads and
    # writes in the prompt length.
    cached_input_tokens = provider == "anthropic" ? cache_creation_tokens.to_i + cache_read_tokens.to_i : 0
    long_context = pricing[:long_context]
    if apply_long_context_pricing && long_context && prompt_tokens.to_i + cached_input_tokens > long_context[:threshold]
      pricing = pricing.merge(long_context)
    end

    # Pricing is per 1M tokens, so divide by 1_000_000
    prompt_cost = (prompt_tokens.to_i * pricing[:prompt]) / 1_000_000.0
    completion_cost = (completion_tokens.to_i * pricing[:completion]) / 1_000_000.0

    # Anthropic prompt-cache tokens bill relative to the input rate: cache writes at 1.25x, cache reads at 0.1x
    # unless the model lists its own cache_read rate. Gated on the provider, because OpenAI cache rates vary by
    # model and its usage already counts cached tokens inside input_tokens.
    cache_creation_cost = 0.0
    cache_read_cost = 0.0
    if provider == "anthropic"
      cache_creation_cost = (cache_creation_tokens.to_i * pricing[:prompt] * 1.25) / 1_000_000.0
      cache_read_cost = (cache_read_tokens.to_i * (pricing[:cache_read] || pricing[:prompt] * 0.10)) / 1_000_000.0
    end

    cost = (prompt_cost + completion_cost + cache_creation_cost + cache_read_cost).round(6)
    Rails.logger.info("Calculated cost for #{provider}/#{model}: $#{cost} (#{prompt_tokens} prompt + #{cache_creation_tokens.to_i} cache-write + #{cache_read_tokens.to_i} cache-read input, #{completion_tokens} completion)")
    cost
  end

  # Find pricing for a model, with prefix matching support
  def self.find_pricing(provider, model)
    return nil unless PRICING.key?(provider)

    model = model.delete_prefix("#{provider}/")

    provider_pricing = PRICING[provider]

    # Claude: the exact version row (ignoring snapshot dates and suffixes), else the family row, so
    # "claude-opus-5-6" doesn't take the "claude-opus-5" rate. Versions written with dots ("claude-opus-4.6")
    # are read with dashes.
    if provider == "anthropic"
      family, version = model.tr(".", "-").match(/\A(claude-[a-z]+)((?:-\d{1,2}(?!\d))*)/)&.captures
      # "-4-0" aliases ("claude-opus-4-0") name the "-4" rows.
      return family && (provider_pricing["#{family}#{version.delete_suffix("-0")}"] || provider_pricing[family])
    end

    # Try exact match first
    return provider_pricing[model] if provider_pricing.key?(model)

    # Try prefix matching longest-first so snapshot IDs for variants (e.g. "gpt-5.4-mini-2026-03-17") do not
    # match a broader family row ("gpt-5.4") before their specific row. A row covers its snapshots but not
    # later versions: "gpt-5" must not price "gpt-5.7-sol".
    provider_pricing.sort_by { |model_prefix, _pricing| -model_prefix.length }.each do |model_prefix, pricing|
      return pricing if model.start_with?(model_prefix) && !model.delete_prefix(model_prefix).match?(/\A\.?\d/)
    end

    tier = model[/\Agpt-[\d.]+-(astra|sol|terra|luna)\b/, 1]
    tier && provider_pricing["gpt-#{tier}"]
  end

  # Infer provider from model name by checking which provider has pricing for it
  # Returns the provider name if found, or "openai" as default (for backward compatibility)
  def self.infer_provider(model)
    return "openai" if model.blank?

    # Bedrock and Vertex prefix Claude model IDs with "anthropic."
    return "anthropic" if model.start_with?("anthropic.", "anthropic/", "claude-")
    return "google" if model.start_with?("gemini-", "google/")

    # Check each provider to see if they have pricing for this model
    PRICING.each do |provider_name, provider_pricing|
      # Try exact match first
      return provider_name if provider_pricing.key?(model)

      # Try prefix matching longest-first to mirror find_pricing
      provider_pricing.keys.sort_by { |model_prefix| -model_prefix.length }.each do |model_prefix|
        return provider_name if model.start_with?(model_prefix)
      end
    end

    # Default to "openai" if no pricing found (for custom/self-hosted models)
    "openai"
  end

  # Aggregate statistics for a family. Spend (total, average, by operation, by model) counts billed rows only;
  # Claude subscription rows add their API-equivalent cost separately.
  def self.statistics_for_family(family, start_date: nil, end_date: nil)
    scope = for_family(family)
    scope = scope.for_date_range(start_date, end_date) if start_date && end_date

    # Exclude records with nil cost and subscription records from cost calculations
    scope_with_cost = scope.billed.where.not(estimated_cost: nil)

    requests_with_cost = scope_with_cost.count
    total_cost = scope_with_cost.sum(:estimated_cost).to_f
    avg_cost = requests_with_cost > 0 ? (total_cost / requests_with_cost).round(4) : 0.0

    subscription_scope = scope.subscription

    {
      total_requests: scope.count,
      billed_requests: scope.billed.count,
      requests_with_cost: requests_with_cost,
      total_prompt_tokens: scope.sum(:prompt_tokens),
      total_completion_tokens: scope.sum(:completion_tokens),
      total_tokens: scope.sum(:total_tokens),
      total_cost: total_cost.round(2),
      avg_cost: avg_cost,
      subscription_requests: subscription_scope.count,
      subscription_equivalent_cost: subscription_scope.sum(:estimated_cost).to_f.round(2),
      by_operation: scope_with_cost.group(:operation).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) },
      by_model: scope_with_cost.group(:model).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) }
    }
  end

  def subscription?
    provider == SUBSCRIPTION_PROVIDER
  end

  # Format cost as currency
  def formatted_cost
    estimated_cost.nil? ? "N/A" : "$#{estimated_cost.round(4)}"
  end

  # Check if this usage record represents a failed API call
  def failed?
    metadata.present? && metadata["error"].present?
  end

  # Get the HTTP status code from metadata
  def http_status_code
    metadata&.dig("http_status_code")
  end

  # Get the error message from metadata
  def error_message
    metadata&.dig("error")
  end

  # Estimate cost for auto-categorizing a batch of transactions
  # Based on typical token usage patterns:
  # - ~100 tokens per transaction in the prompt
  # - ~50 tokens per category
  # - ~50 tokens for completion per transaction
  # Returns nil if pricing is not available for the model
  def self.estimate_auto_categorize_cost(transaction_count:, category_count:, model: "gpt-4.1")
    return 0.0 if transaction_count.zero?

    # Estimate tokens
    base_prompt_tokens = 150 # System message and instructions
    transaction_tokens = transaction_count * 100
    category_tokens = category_count * 50
    estimated_prompt_tokens = base_prompt_tokens + transaction_tokens + category_tokens

    # Completion tokens: roughly one category name per transaction
    estimated_completion_tokens = transaction_count * 50

    # calculate_cost will automatically infer the provider from the model
    # Returns nil if pricing is not available
    calculate_cost(
      model: model,
      prompt_tokens: estimated_prompt_tokens,
      completion_tokens: estimated_completion_tokens,
      apply_long_context_pricing: false
    )
  end
end
