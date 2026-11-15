require "test_helper"

# Runs on a saved LiteLLM-shaped price list (test/fixtures/files/llm_pricing_source.json), never the network
class LlmPricingUpdaterTest < ActiveSupport::TestCase
  CONFIG = <<~YAML
    verified_on: 2026-10-17

    providers:
      openai:
        # GPT-6
        gpt-6.1-sol: &gpt-6-1-sol { prompt: 2.0, completion: 10.0 } # promotion {ends Q4}
        gpt-4.1: { prompt: 2.0, completion: 8.0 }
        gpt-4o: { prompt: 2.5, completion: 10.0 }
        gpt-5.4: { prompt: 2.5, completion: 15.0, long_context: { threshold: 272000, prompt: 5.0, completion: 22.5 } }
        gpt-sol: *gpt-6-1-sol
      google:
        gemini-2.5-flash: { prompt: 0.3, completion: 2.5 }
      anthropic:
        claude-opus-5-5: &claude-opus-5-5 { prompt: 4.0, completion: 20.0, cache_read: 0.2 }
        claude-opus: *claude-opus-5-5
  YAML

  setup do
    Net::HTTP.expects(:get_response).never
    @prices = JSON.parse(file_fixture("llm_pricing_source.json").read)
    @result = LlmPricingUpdater.new(CONFIG, @prices).call
    @lines = @result.yaml.lines(chomp: true)
  end

  test "rewrites changed rows in place, keeping comments, anchors and aliases" do
    assert_includes @lines, "    gpt-6.1-sol: &gpt-6-1-sol { prompt: 3.0, completion: 12.0, " \
      "long_context: { threshold: 272000, prompt: 6.0, completion: 18.0 } } # promotion {ends Q4}"
    assert_includes @lines, "    # GPT-6"
    assert_includes @lines, "    gpt-4.1: { prompt: 2.0, completion: 8.0 }"
    assert_includes @lines, "    claude-opus-5-5: &claude-opus-5-5 { prompt: 4.0, completion: 20.0, cache_read: 0.2 }"
    assert_equal [ "`openai/gpt-6.1-sol`" ], @result.changed.map { |line| line.split(":").first }

    loaded = YAML.safe_load(@result.yaml, permitted_classes: [ Date ], aliases: true)
    assert_equal 3.0, loaded.dig("providers", "openai", "gpt-sol", "prompt"), "the alias follows the rewritten anchor"
    assert_equal Date.new(2026, 10, 17), loaded["verified_on"], "verified_on changes only after a manual review"
  end

  test "adds new Claude and GPT tier releases only, from the right provider" do
    assert_includes @lines, "    gpt-6.2-sol: { prompt: 2.0, completion: 10.0 }"
    assert_includes @lines, "    claude-sonnet-6: { prompt: 2.0, completion: 10.0 }"
    assert_equal 2, @result.added.size
    assert_not @result.yaml.include?("gpt-5.9"), "a plain version is left to the family rows"
    assert_not @result.yaml.include?("claude-opus-4-20250514"), "dated snapshots are left to the existing rows"
    assert_not @result.yaml.include?("claude-haiku-6"), "rows from another LiteLLM provider are ignored"
  end

  test "reports rows it cannot confirm and leaves them unchanged" do
    assert_includes @lines, "    gpt-4o: { prompt: 2.5, completion: 10.0 }"
    assert_includes @lines, "    gpt-5.4: { prompt: 2.5, completion: 15.0, long_context: { threshold: 272000, prompt: 5.0, completion: 22.5 } }"
    assert @result.missing.any? { |line| line.include?("openai/gpt-4o") }
    assert @result.missing.any? { |line| line.include?("openai/gpt-5.4") && line.include?("long-context") }
  end

  test "the summary lists each section" do
    assert_includes @result.summary, "### Changed"
    assert_includes @result.summary, "### Added"
    assert_includes @result.summary, "### Left unchanged"
  end

  test "the bundled config still loads after an update from the fixture" do
    config = Rails.root.join("config/llm_pricing.yml").read
    result = LlmPricingUpdater.new(config, @prices).call

    loaded = YAML.safe_load(result.yaml, permitted_classes: [ Date ], aliases: true)
    assert_equal LlmUsage::PRICING_VERIFIED_ON, loaded["verified_on"]
    assert_equal LlmUsage::PRICING.keys, loaded["providers"].keys
  end
end
