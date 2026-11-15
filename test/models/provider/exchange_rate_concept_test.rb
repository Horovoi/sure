require "test_helper"

# Every exchange rate provider gets Provider::ExchangeRateConcept::RateValidation prepended,
# so a zero, negative or non-finite rate never reaches a caller as a usable one.
class Provider::ExchangeRateConceptTest < ActiveSupport::TestCase
  class FakeProvider < Provider
    include Provider::ExchangeRateConcept

    Error = Class.new(Provider::Error)

    def initialize(rate)
      @rate = rate
    end

    def fetch_exchange_rate(from:, to:, date:)
      with_provider_response { Rate.new(date: date, from: from, to: to, rate: @rate) }
    end

    def fetch_exchange_rates(from:, to:, start_date:, end_date:)
      with_provider_response do
        (start_date..end_date).map.with_index do |date, i|
          Rate.new(date: date, from: from, to: to, rate: i.zero? ? @rate : 41)
        end
      end
    end
  end

  test "a usable rate passes through" do
    response = FakeProvider.new(41.5).fetch_exchange_rate(from: "USD", to: "UAH", date: Date.current)

    assert response.success?
    assert_equal 41.5, response.data.rate
  end

  test "an unusable single rate becomes a failed response and is logged" do
    [ 0, -3, BigDecimal("NaN"), BigDecimal("Infinity"), nil ].each do |value|
      assert_difference -> { DebugLogEntry.where(category: "exchange_rates", level: "warn").count }, 1 do
        response = FakeProvider.new(value).fetch_exchange_rate(from: "USD", to: "UAH", date: Date.current)

        assert_not response.success?, "#{value.inspect} must not be a usable rate"
        assert_nil response.data
        assert_kind_of FakeProvider::Error, response.error
      end
    end
  end

  test "unusable rows are dropped from a series" do
    response = FakeProvider.new(0).fetch_exchange_rates(from: "USD", to: "UAH", start_date: 2.days.ago.to_date, end_date: Date.current)

    assert response.success?
    assert_equal [ 41, 41 ], response.data.map(&:rate)
  end

  test "the NBU provider returns a failed response for a zero rate" do
    provider = Provider::Nbu.new
    mock_response = mock
    mock_response.stubs(:body).returns('[{"r030":840,"txt":"USD","rate":0,"cc":"USD","exchangedate":"14.11.2026"}]')
    provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = provider.fetch_exchange_rate(from: "USD", to: "UAH", date: Date.new(2026, 11, 14))

    assert_not response.success?
    assert_kind_of Provider::Nbu::Error, response.error
    assert_equal "nbu", DebugLogEntry.where(category: "exchange_rates").last.provider_key
  end
end
