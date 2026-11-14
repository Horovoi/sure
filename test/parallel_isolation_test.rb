require "test_helper"

# Guards the setup in test_helper: tests in different workers must not share Redis.
class ParallelIsolationTest < ActiveSupport::TestCase
  test "each parallel worker has its own Redis database" do
    worker = ActiveSupport::TestCase.parallel_worker_id
    skip "not running in parallel" if worker.nil?

    expected = worker % 15 + 1

    assert_equal expected, Sidekiq.redis { |redis| redis.config.db }, "Sidekiq (cron jobs)"
    assert_equal expected, Redis.new.connection[:db], "Redis.new (rate limits)"
  end
end
