require "test_helper"

class Provider::RateLimitableTest < ActiveSupport::TestCase
  class Client
    include Provider::RateLimitable

    PROVIDER_ENV_PREFIX = "TESTBANK"
    MIN_REQUEST_INTERVAL = 60.0

    def initialize(token)
      @token = token
    end

    def rate_limit_scope_key
      Digest::SHA256.hexdigest(@token)
    end

    def sleep(*)
      raise "a rate-limited client must never sleep"
    end
  end

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @client = Client.new("token-a")
  end

  test "reserves a free slot and refuses the next request until the interval passed" do
    next_free = @client.reserve_request_slot!(:statement)
    assert_equal Time.current + 60, next_free

    busy = assert_raises(Provider::RateLimitable::SlotBusy) { @client.reserve_request_slot!(:statement) }
    assert_equal :statement, busy.bucket
    assert_equal Time.current + 60, busy.retry_at

    travel 60.seconds
    assert_equal Time.current + 60, @client.reserve_request_slot!(:statement)
  end

  test "buckets and credentials are separate" do
    @client.reserve_request_slot!(:statement)

    assert @client.reserve_request_slot!(:client_info)
    assert Client.new("token-b").reserve_request_slot!(:statement)
  end

  test "next_request_slot_at is now while free and the reserved time after" do
    assert_equal Time.current, @client.next_request_slot_at(:statement)

    @client.reserve_request_slot!(:statement)

    assert_equal Time.current + 60, @client.next_request_slot_at(:statement)
  end

  test "defer pushes the slot out and never pulls it in" do
    @client.reserve_request_slot!(:statement)

    @client.defer_request_slot!(:statement, Time.current + 5.minutes)
    assert_equal Time.current + 5.minutes, @client.next_request_slot_at(:statement)

    @client.defer_request_slot!(:statement, Time.current + 1.minute)
    assert_equal Time.current + 5.minutes, @client.next_request_slot_at(:statement)

    @client.defer_request_slot!(:client_info, Time.current + 2.minutes)
    assert_raises(Provider::RateLimitable::SlotBusy) { @client.reserve_request_slot!(:client_info) }
  end

  test "the interval comes from the environment" do
    with_env_overrides("TESTBANK_MIN_REQUEST_INTERVAL" => "1.5") do
      assert_equal 1.5, @client.min_request_interval
      assert_equal Time.current + 1.5, @client.reserve_request_slot!(:x)
    end
  end

  test "an interval that is not a positive number is an error" do
    [ "0", "-1", "abc", "" ].each do |value|
      with_env_overrides("TESTBANK_MIN_REQUEST_INTERVAL" => value) do
        assert_raises(ArgumentError, value) { @client.min_request_interval }
      end
    end
  end

  test "a repeated reservation is not answered from the query cache" do
    ActiveRecord::Base.cache do
      @client.reserve_request_slot!(:statement)
      assert_raises(Provider::RateLimitable::SlotBusy) { @client.reserve_request_slot!(:statement) }
      assert_equal Time.current + 60, @client.next_request_slot_at(:statement)
    end
  end

  test "the slot row holds a digest, never the credential" do
    @client.reserve_request_slot!(:statement)

    slot = ProviderRateLimitSlot.find_by!(provider_key: "testbank", bucket: "statement")
    assert_not_includes slot.scope_key, "token-a"
  end
end

# Real concurrency needs separate connections, so these rows are committed and removed
class Provider::RateLimitableConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @scope = "concurrency-#{SecureRandom.hex(8)}"
  end

  teardown do
    ProviderRateLimitSlot.where(scope_key: @scope).delete_all
  end

  test "of concurrent reservations exactly one gets the slot" do
    results = Queue.new
    gate = Concurrent::CountDownLatch.new(1)

    # Two threads: the test pool has 3 connections and this thread holds one
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.wait
          results << ProviderRateLimitSlot.reserve(provider_key: "testbank", scope_key: @scope, bucket: "statement", interval: 60).first
        end
      end
    end
    gate.count_down
    threads.each(&:join)

    outcomes = 2.times.map { results.pop }
    assert_equal 1, outcomes.count(true)
    assert_equal 1, outcomes.count(false)
  end
end
