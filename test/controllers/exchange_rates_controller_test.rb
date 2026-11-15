require "test_helper"

class ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    sign_in users(:family_admin)
    ExchangeRate.stubs(:provider).returns(nil)
  end

  test "returns the day's stored rate" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 11, 2), rate: 41.5)

    get exchange_rate_url(from: "usd", to: "UAH", date: "2026-11-02")

    assert_response :success
    body = response.parsed_body
    assert_equal 41.5, body["rate"]
    assert_equal "2026-11-02", body["date"]
    assert_equal "USD", body["from"]
  end

  test "follows the nearest-rate rule and names the date of the rate it used" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 10, 20), rate: 41)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 10, 28), rate: 41.2)

    get exchange_rate_url(from: "USD", to: "UAH", date: "2026-11-02")

    assert_response :success
    assert_equal 41.2, response.parsed_body["rate"]
    assert_equal "2026-10-28", response.parsed_body["date"]
    assert_equal "2026-11-02", response.parsed_body["requested_date"]
  end

  test "uses the earliest later rate when nothing is stored before the date" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 11, 5), rate: 42)

    get exchange_rate_url(from: "USD", to: "UAH", date: "2026-11-02")

    assert_response :success
    assert_equal 42.0, response.parsed_body["rate"]
  end

  test "answers 404 with no rate, never 1" do
    get exchange_rate_url(from: "PLN", to: "UAH")

    assert_response :not_found
    assert_equal "rate_unavailable", response.parsed_body["error"]
    assert_nil response.parsed_body["rate"]
  end

  # A stored rate is always above zero (validation and chk_exchange_rates_rate_positive),
  # so a zero can only come from the provider
  test "a rate of zero is no rate" do
    provider = mock
    provider.expects(:fetch_exchange_rate).at_least_once.returns(
      provider_success_response(OpenStruct.new(from: "PLN", to: "UAH", date: Date.current, rate: 0))
    )
    ExchangeRate.stubs(:provider).returns(provider)

    assert_no_difference "ExchangeRate.count" do
      get exchange_rate_url(from: "PLN", to: "UAH")
    end

    assert_response :not_found
  end

  test "the same currency is 1" do
    get exchange_rate_url(from: "UAH", to: "uah")

    assert_response :success
    assert_equal 1.0, response.parsed_body["rate"]
    assert response.parsed_body["same_currency"]
  end

  test "rejects a missing or unknown currency and a bad date" do
    get exchange_rate_url(from: "USD")
    assert_response :bad_request

    get exchange_rate_url(from: "USD", to: "NOPE")
    assert_response :bad_request
    assert_equal "invalid_currency", response.parsed_body["error"]

    get exchange_rate_url(from: "USD", to: "UAH", date: "not-a-date")
    assert_response :bad_request
    assert_equal "invalid_date", response.parsed_body["error"]
  end

  test "a future date asks for today's rate" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 41.9)

    get exchange_rate_url(from: "USD", to: "UAH", date: 10.days.from_now.to_date.iso8601)

    assert_response :success
    assert_equal Date.current.iso8601, response.parsed_body["requested_date"]
  end

  test "needs a signed-in user" do
    reset!

    get exchange_rate_url(from: "USD", to: "UAH")

    assert_response :redirect
  end
end
