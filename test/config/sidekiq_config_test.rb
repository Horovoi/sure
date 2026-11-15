require "test_helper"

class SidekiqConfigTest < ActiveSupport::TestCase
  AI_QUEUES = %w[ai_high_priority ai_low_priority].freeze

  AI_JOBS = {
    AssistantResponseJob => "ai_high_priority",
    AutoCategorizeJob => "ai_low_priority",
    AutoDetectMerchantsJob => "ai_low_priority",
    ProcessPdfJob => "ai_low_priority"
  }.freeze

  test "production threads: the ai capsule has 2 threads and only the AI queues, the default lane 3" do
    with_env_overrides("RAILS_MAX_THREADS" => "5", "RAILS_AI_MAX_THREADS" => "2") do
      config = sidekiq_config

      assert_equal 2, config.dig(:capsules, :ai, :concurrency)
      assert_equal AI_QUEUES, config.dig(:capsules, :ai, :queues), "strict order: chat first, no weights"
      assert_equal 3, config[:concurrency]
      assert_empty config[:queues].map(&:first) & AI_QUEUES, "the default lane never runs AI jobs"
      assert_equal database_pool, config[:concurrency] + config.dig(:capsules, :ai, :concurrency)
    end
  end

  test "defaults: 3 threads in all, 1 of them for AI" do
    with_env_overrides("RAILS_MAX_THREADS" => nil, "RAILS_AI_MAX_THREADS" => nil) do
      config = sidekiq_config

      assert_equal 2, config[:concurrency]
      assert_equal 1, config.dig(:capsules, :ai, :concurrency)
      assert_equal database_pool, config[:concurrency] + config.dig(:capsules, :ai, :concurrency)
    end
  end

  test "the default lane keeps at least one thread" do
    with_env_overrides("RAILS_MAX_THREADS" => "1", "RAILS_AI_MAX_THREADS" => "1") do
      assert_equal 1, sidekiq_config[:concurrency]
    end
  end

  test "the production worker sets 5 threads with 2 for AI" do
    compose = YAML.safe_load(Rails.root.join("docker-compose.prod.yml").read, aliases: true)
    worker_env = compose.dig("services", "worker", "environment")

    assert_equal 5, worker_env["RAILS_MAX_THREADS"].to_i
    assert_equal 2, worker_env["RAILS_AI_MAX_THREADS"].to_i
    assert_nil compose.dig("services", "web", "environment", "RAILS_AI_MAX_THREADS"), "Puma keeps its own thread count"
  end

  test "AI jobs run on the ai capsule's queues" do
    AI_JOBS.each { |job, queue| assert_equal queue, job.queue_name, job.name }
  end

  private
    def sidekiq_config
      erb = ERB.new(Rails.root.join("config/sidekiq.yml").read, trim_mode: "-")
      YAML.safe_load(erb.result, permitted_classes: [ Symbol ], aliases: true).deep_symbolize_keys
    end

    def database_pool
      erb = ERB.new(Rails.root.join("config/database.yml").read)
      YAML.safe_load(erb.result, aliases: true).dig("production", "pool").to_i
    end
end
