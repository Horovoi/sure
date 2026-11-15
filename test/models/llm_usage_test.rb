require "test_helper"

class LlmUsageTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "pricing loads from config/llm_pricing.yml with its review date" do
    assert_kind_of Date, LlmUsage::PRICING_VERIFIED_ON
    assert LlmUsage::PRICING.key?("openai")
    assert LlmUsage::PRICING.key?("anthropic")
    assert LlmUsage::PRICING.frozen?
  end

  test "an OpenAI model is priced per million tokens, including dated snapshots" do
    assert_in_delta 0.006, LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1_000, completion_tokens: 500), 1e-9
    assert_in_delta 0.006, LlmUsage.calculate_cost(model: "gpt-4.1-2025-04-14", prompt_tokens: 1_000, completion_tokens: 500), 1e-9
    assert_equal "openai", LlmUsage.infer_provider("gpt-4.1")
  end

  test "a variant row wins over its broader family row" do
    mini = LlmUsage::PRICING.dig("openai", "gpt-4.1-mini")

    assert_equal mini, LlmUsage.find_pricing("openai", "gpt-4.1-mini-2025-04-14")
  end

  test "a Claude model is priced from its version row, then its family row" do
    assert_equal "anthropic", LlmUsage.infer_provider("claude-sonnet-4-5")
    assert_in_delta 0.018, LlmUsage.calculate_cost(model: "claude-sonnet-4-5", prompt_tokens: 1_000, completion_tokens: 1_000), 1e-9

    assert_equal LlmUsage::PRICING.dig("anthropic", "claude-opus-4-1"), LlmUsage.find_pricing("anthropic", "claude-opus-4-1-20250805")
    assert_equal LlmUsage::PRICING.dig("anthropic", "claude-opus"), LlmUsage.find_pricing("anthropic", "claude-opus-6")
  end

  test "Claude cache writes bill at 1.25x input and cache reads at 0.1x unless the model lists a rate" do
    cost = LlmUsage.calculate_cost(
      model: "claude-sonnet-4-5", prompt_tokens: 1_000, completion_tokens: 1_000,
      cache_creation_tokens: 1_000, cache_read_tokens: 1_000
    )
    # 0.003 input + 0.015 output + 0.00375 cache write (3.0 * 1.25) + 0.0003 cache read (3.0 * 0.1)
    assert_in_delta 0.02205, cost, 1e-9

    listed_rate = LlmUsage.calculate_cost(model: "claude-opus-5-5", prompt_tokens: 0, completion_tokens: 0, cache_read_tokens: 1_000_000)
    assert_in_delta LlmUsage::PRICING.dig("anthropic", "claude-opus-5-5", :cache_read), listed_rate, 1e-9
  end

  test "cache tokens are ignored for OpenAI, whose input tokens already include them" do
    assert_in_delta 0.006, LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1_000, completion_tokens: 500, cache_read_tokens: 10_000), 1e-9
  end

  test "the long-context tier applies only above its threshold" do
    tier = LlmUsage::PRICING.dig("openai", "gpt-5.4")
    threshold = tier[:long_context][:threshold]

    at_threshold = LlmUsage.calculate_cost(model: "gpt-5.4", prompt_tokens: threshold, completion_tokens: 0)
    above = LlmUsage.calculate_cost(model: "gpt-5.4", prompt_tokens: threshold + 1, completion_tokens: 0)

    assert_in_delta threshold * tier[:prompt] / 1_000_000.0, at_threshold, 1e-6
    assert_in_delta (threshold + 1) * tier[:long_context][:prompt] / 1_000_000.0, above, 1e-6
    assert_in_delta threshold * tier[:prompt] / 1_000_000.0,
      LlmUsage.calculate_cost(model: "gpt-5.4", prompt_tokens: threshold + 1, completion_tokens: 0, apply_long_context_pricing: false), 1e-3
  end

  test "Claude cache tokens count toward the long-context threshold" do
    tier = LlmUsage::PRICING.dig("anthropic", "claude-haiku-5-5")
    long = tier[:long_context]

    cost = LlmUsage.calculate_cost(model: "claude-haiku-5-5", prompt_tokens: long[:threshold] / 2, completion_tokens: 0, cache_read_tokens: long[:threshold])

    expected = (long[:threshold] / 2) * long[:prompt] / 1_000_000.0 + long[:threshold] * long[:prompt] * 0.1 / 1_000_000.0
    assert_in_delta expected, cost, 1e-9
  end

  test "an unknown or blank model has no cost" do
    assert_nil LlmUsage.calculate_cost(model: "my-local-model", prompt_tokens: 1_000, completion_tokens: 1_000)
    assert_nil LlmUsage.calculate_cost(model: "", prompt_tokens: 1_000, completion_tokens: 1_000)
    assert_equal "openai", LlmUsage.infer_provider("my-local-model")
  end

  test "statistics leave Claude subscription rows out of the spend" do
    @family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "chat", prompt_tokens: 100, completion_tokens: 50, total_tokens: 150, estimated_cost: 1.25)
    @family.llm_usages.create!(provider: LlmUsage::SUBSCRIPTION_PROVIDER, model: "claude-opus-5-5", operation: "chat", prompt_tokens: 1_000, completion_tokens: 500, total_tokens: 1_500, estimated_cost: 3.5)

    stats = LlmUsage.statistics_for_family(@family)

    assert_equal 2, stats[:total_requests]
    assert_equal 1, stats[:billed_requests]
    assert_equal 1.25, stats[:total_cost]
    assert_equal 1.25, stats[:avg_cost]
    assert_equal 1, stats[:subscription_requests]
    assert_equal 3.5, stats[:subscription_equivalent_cost]
    assert_equal({ "gpt-4.1" => 1.25 }, stats[:by_model])
    assert_equal 1_650, stats[:total_tokens]
  end

  test "subscription? marks Claude subscription rows" do
    assert LlmUsage.new(provider: LlmUsage::SUBSCRIPTION_PROVIDER).subscription?
    assert_not LlmUsage.new(provider: "anthropic").subscription?
  end
end
