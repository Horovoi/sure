require "test_helper"

class Security::HealthCheckerTest < ActiveSupport::TestCase
  include ProviderTestHelper

  NotFoundError = Class.new(Provider::Error) { include Provider::SecurityConcept::SecurityNotFound }

  setup do
    # Clean slate
    Holding.destroy_all
    Trade.destroy_all
    Security::Price.delete_all
    Security.delete_all

    @provider = mock
    Security.stubs(:provider).returns(@provider)

    # Brand new, no health check has been run yet
    @new_security = Security.create!(ticker: "NEW", last_health_check_at: nil)

    # Online, recently checked, healthy
    @healthy_security = Security.create!(ticker: "HEALTHY", last_health_check_at: 2.hours.ago)

    # Online, due for a health check
    @due_for_check_security = Security.create!(
      ticker: "DUE",
      last_health_check_at: Security::HealthChecker::HEALTH_CHECK_INTERVAL.ago - 1.day
    )

    # Unavailable and due: still rechecked so it can come back
    @unavailable_security = Security.create!(
      ticker: "GONE",
      status: "unavailable",
      failed_fetch_count: 6,
      failed_fetch_at: 8.days.ago,
      last_health_check_at: Security::HealthChecker::HEALTH_CHECK_INTERVAL.ago - 1.day
    )

    # Manual securities are never checked, even if never checked before
    @manual_security = Security.create!(ticker: "MANUAL", status: "manual", last_health_check_at: nil)
  end

  test "checks never-checked and due securities, but not manual ones" do
    checked = []
    Security::HealthChecker.stubs(:new).with { |security| checked << security.ticker }.returns(stub(run_check: nil))

    Security::HealthChecker.check_all

    assert_equal %w[DUE GONE NEW], checked.sort
  end

  test "does nothing without a provider" do
    Security.stubs(:provider).returns(nil)
    Security::HealthChecker.expects(:new).never

    Security::HealthChecker.check_all

    assert_nil @new_security.reload.last_health_check_at
  end

  test "asks for the latest bar in the lookback window instead of today" do
    travel_to Time.zone.parse("2026-11-16 02:00 UTC") do # a Monday, before the day's bar exists
      expect_prices(@new_security, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 16))
        .returns(provider_success_response([ price(Date.new(2026, 11, 13)) ]))

      Security::HealthChecker.new(@new_security).run_check
    end

    assert @new_security.reload.online?
    assert_equal 0, @new_security.failed_fetch_count
    assert_not_nil @new_security.last_health_check_at
  end

  test "a not-found answer counts as a failed check and degrades the security" do
    expect_prices(@due_for_check_security).returns(provider_error_response(NotFoundError.new("symbol not found")))

    Security::HealthChecker.new(@due_for_check_security).run_check

    @due_for_check_security.reload
    assert @due_for_check_security.degraded?
    assert @due_for_check_security.fetchable?
    assert_equal 1, @due_for_check_security.failed_fetch_count
    assert_in_delta Time.current, @due_for_check_security.last_health_check_at, 5.seconds
  end

  test "no bars in the lookback window counts as a failed check" do
    expect_prices(@due_for_check_security).returns(provider_success_response([]))

    Security::HealthChecker.new(@due_for_check_security).run_check

    assert_equal 1, @due_for_check_security.reload.failed_fetch_count
  end

  test "after enough consecutive failures the security becomes unavailable and keeps its prices" do
    Security::Price.create!(security: @due_for_check_security, date: Date.current, price: 100, currency: "USD")

    expect_prices(@due_for_check_security)
      .returns(provider_error_response(NotFoundError.new("symbol not found")))
      .times(Security::HealthChecker::MAX_CONSECUTIVE_FAILURES + 1)

    hc = Security::HealthChecker.new(@due_for_check_security)
    Security::HealthChecker::MAX_CONSECUTIVE_FAILURES.times { hc.run_check }

    assert @due_for_check_security.reload.degraded?

    hc.run_check

    @due_for_check_security.reload
    assert @due_for_check_security.unavailable?
    refute @due_for_check_security.fetchable?
    assert @due_for_check_security.offline, "legacy offline column mirrors the status"
    assert_equal 1, @due_for_check_security.prices.count
  end

  test "rate limits, outages and missing configuration are not counted" do
    [
      Provider::YahooFinance::RateLimitError.new("rate limited"),
      Provider::TwelveData::Error.new("the server responded with status 500"),
      Provider::TwelveData::InvalidSecurityPriceError.new("API error (code: 429): You have run out of API credits")
    ].each do |error|
      expect_prices(@due_for_check_security).returns(provider_error_response(error)).once
      Security::HealthChecker.new(@due_for_check_security).run_check
    end

    @due_for_check_security.reload
    assert @due_for_check_security.online?
    assert_equal 0, @due_for_check_security.failed_fetch_count
    assert_operator @due_for_check_security.last_health_check_at, :<, 7.days.ago, "inconclusive checks are retried on the next run"
  end

  test "an unexpected error is neither counted nor stamped" do
    expect_prices(@due_for_check_security).raises(StandardError, "boom")

    Security::HealthChecker.new(@due_for_check_security).run_check

    @due_for_check_security.reload
    assert_equal 0, @due_for_check_security.failed_fetch_count
    assert_operator @due_for_check_security.last_health_check_at, :<, 7.days.ago
  end

  test "an unavailable security that is found again goes back online" do
    expect_prices(@unavailable_security).returns(provider_success_response([ price(Date.current) ]))

    Security::HealthChecker.new(@unavailable_security).run_check

    @unavailable_security.reload
    assert @unavailable_security.online?
    refute @unavailable_security.offline
    assert_equal 0, @unavailable_security.failed_fetch_count
    assert_nil @unavailable_security.failed_fetch_at
  end

  test "a manual security is never turned online" do
    @provider.expects(:fetch_security_prices).never

    Security::HealthChecker.new(@manual_security).run_check

    assert @manual_security.reload.manual?
  end

  private
    def expect_prices(security, start_date: Security::HealthChecker::LOOKBACK.ago.to_date, end_date: Date.current)
      @provider.expects(:fetch_security_prices).with(
        symbol: security.ticker,
        exchange_operating_mic: security.exchange_operating_mic,
        start_date: start_date,
        end_date: end_date
      )
    end

    def price(date)
      Provider::SecurityConcept::Price.new(symbol: "X", date: date, price: 100, currency: "USD", exchange_operating_mic: nil)
    end
end
