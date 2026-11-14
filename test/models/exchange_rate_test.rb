require "test_helper"
require "ostruct"

class ExchangeRateTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock

    ExchangeRate.stubs(:provider).returns(@provider)
  end

  test "finds rate in DB" do
    existing_rate = exchange_rates(:one)

    @provider.expects(:fetch_exchange_rate).never

    assert_equal existing_rate, ExchangeRate.find_or_fetch_rate(
                                              from: existing_rate.from_currency,
                                              to: existing_rate.to_currency,
                                              date: existing_rate.date
                                            )
  end

  test "fetches rate from provider without cache" do
    ExchangeRate.delete_all

    provider_response = provider_success_response(
      OpenStruct.new(
        from: "USD",
        to: "EUR",
        date: Date.current,
        rate: 1.2
      )
    )

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_no_difference "ExchangeRate.count" do
      assert_equal 1.2, ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: false).rate
    end
  end

  test "fetches rate from provider with cache" do
    ExchangeRate.delete_all

    provider_response = provider_success_response(
      OpenStruct.new(
        from: "USD",
        to: "EUR",
        date: Date.current,
        rate: 1.2
      )
    )

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_difference "ExchangeRate.count", 1 do
      assert_equal 1.2, ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true).rate
    end
  end

  test "returns nil on provider error" do
    provider_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_exchange_rate).returns(provider_response)

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: true)
  end

  test "asks the provider once per pair and date when it has no rate" do
    ExchangeRate.delete_all

    @provider.expects(:fetch_exchange_rate)
             .with(from: "USD", to: "EUR", date: Date.current)
             .once
             .returns(provider_error_response(StandardError.new("Test error")))

    3.times do
      assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current)
    end
  end

  test "reuses a fetched rate that is not stored" do
    ExchangeRate.delete_all

    provider_response = provider_success_response(
      OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 1.2)
    )

    @provider.expects(:fetch_exchange_rate).once.returns(provider_response)

    assert_no_difference "ExchangeRate.count" do
      2.times do
        assert_equal 1.2, ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current, cache: false).rate
      end
    end
  end

  test "asks the provider separately for each pair and date" do
    ExchangeRate.delete_all

    error_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_exchange_rate).with(from: "USD", to: "EUR", date: Date.current).once.returns(error_response)
    @provider.expects(:fetch_exchange_rate).with(from: "GBP", to: "EUR", date: Date.current).once.returns(error_response)
    @provider.expects(:fetch_exchange_rate).with(from: "USD", to: "EUR", date: Date.yesterday).once.returns(error_response)

    2.times do
      assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current)
      assert_nil ExchangeRate.find_or_fetch_rate(from: "GBP", to: "EUR", date: Date.current)
      assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.yesterday)
    end
  end

  test "asks the provider again in the next request or job" do
    ExchangeRate.delete_all

    @provider.expects(:fetch_exchange_rate)
             .twice
             .returns(provider_error_response(StandardError.new("Test error")))

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current)

    # Rails does this between requests and between jobs
    ActiveSupport::CurrentAttributes.reset_all

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current)
  end
end
