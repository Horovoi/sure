require "test_helper"

class Provider::NbuTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Nbu.new
  end

  # ================================
  #        Health Check Tests
  # ================================

  test "healthy? returns true when API is working" do
    mock_response = mock
    mock_response.stubs(:body).returns('[{"r030":840,"txt":"Долар США","rate":43.1759,"cc":"USD","exchangedate":"25.01.2026"}]')

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    assert_equal true, @provider.healthy?
  end

  test "healthy? returns false when API fails" do
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(Faraday::Error.new("Connection failed"))

    assert_equal false, @provider.healthy?
  end

  test "healthy? returns false when API returns empty response" do
    mock_response = mock
    mock_response.stubs(:body).returns("[]")

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    assert_equal false, @provider.healthy?
  end

  # ================================
  #          Usage Tests
  # ================================

  test "usage returns free plan info" do
    response = @provider.usage
    assert response.success?
    assert_equal "Free (National Bank of Ukraine)", response.data.plan
    assert_equal 0, response.data.used
    assert_nil response.data.limit
  end

  # ================================
  #      Exchange Rate Tests
  # ================================

  test "fetch_exchange_rate returns 1.0 for UAH to UAH" do
    date = Date.parse("2026-01-25")
    response = @provider.fetch_exchange_rate(from: "UAH", to: "UAH", date: date)

    assert response.success?
    rate = response.data
    assert_equal 1.0, rate.rate
    assert_equal "UAH", rate.from
    assert_equal "UAH", rate.to
    assert_equal date, rate.date
  end

  test "fetch_exchange_rate returns correct rate for USD to UAH" do
    date = Date.parse("2026-01-25")
    nbu_rate = 43.1759

    mock_response = mock
    mock_response.stubs(:body).returns("[{\"r030\":840,\"txt\":\"Долар США\",\"rate\":#{nbu_rate},\"cc\":\"USD\",\"exchangedate\":\"25.01.2026\"}]")

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rate(from: "USD", to: "UAH", date: date)

    assert response.success?
    rate = response.data
    assert_equal nbu_rate.to_d, rate.rate
    assert_equal "USD", rate.from
    assert_equal "UAH", rate.to
    assert_equal date, rate.date
  end

  test "fetch_exchange_rate returns inverted rate for UAH to USD" do
    date = Date.parse("2026-01-25")
    nbu_rate = 43.1759

    mock_response = mock
    mock_response.stubs(:body).returns("[{\"r030\":840,\"txt\":\"Долар США\",\"rate\":#{nbu_rate},\"cc\":\"USD\",\"exchangedate\":\"25.01.2026\"}]")

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rate(from: "UAH", to: "USD", date: date)

    assert response.success?
    rate = response.data
    expected_rate = (1.0 / nbu_rate).round(8)
    assert_equal expected_rate, rate.rate
    assert_equal "UAH", rate.from
    assert_equal "USD", rate.to
    assert_equal date, rate.date
  end

  test "fetch_exchange_rate delegates to fallback for non-UAH currency pairs" do
    date = Date.parse("2026-01-25")

    # Mock the fallback provider (Yahoo Finance)
    mock_fallback = mock
    expected_rate = Provider::ExchangeRateConcept::Rate.new(date: date, from: "USD", to: "EUR", rate: 0.92)
    mock_fallback.expects(:fetch_exchange_rate).with(from: "USD", to: "EUR", date: date).returns(
      Provider::Response.new(success?: true, data: expected_rate, error: nil)
    )
    @provider.instance_variable_set(:@fallback_provider, mock_fallback)

    response = @provider.fetch_exchange_rate(from: "USD", to: "EUR", date: date)

    assert response.success?
    assert_equal "USD", response.data.from
    assert_equal "EUR", response.data.to
  end

  test "fetch_exchange_rate handles empty API response" do
    date = Date.parse("2026-01-25")

    mock_response = mock
    mock_response.stubs(:body).returns("[]")

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rate(from: "USD", to: "UAH", date: date)

    assert_not response.success?
    assert_instance_of Provider::Nbu::InvalidExchangeRateError, response.error
  end

  # ================================
  #    Exchange Rates Range Tests
  # ================================

  test "fetch_exchange_rates returns rates for date range" do
    start_date = Date.parse("2026-01-23")
    end_date = Date.parse("2026-01-25")

    mock_response = mock
    mock_response.stubs(:body).returns(nbu_range_body("USD", { "23.01.2026" => 43.1, "24.01.2026" => 43.2, "25.01.2026" => 43.3 }))

    # The whole range comes from a single request, not one request per day
    mock_client = mock
    mock_client.expects(:get).once.returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rates(from: "USD", to: "UAH", start_date: start_date, end_date: end_date)

    assert response.success?
    rates = response.data
    assert_equal [ start_date, start_date + 1.day, end_date ], rates.map(&:date)
    assert_equal [ 43.1, 43.2, 43.3 ], rates.map { |r| r.rate.to_f }
    assert rates.all? { |r| r.from == "USD" }
    assert rates.all? { |r| r.to == "UAH" }
  end

  test "fetch_exchange_rates inverts rates when converting from UAH" do
    date = Date.parse("2026-01-23")

    mock_response = mock
    mock_response.stubs(:body).returns(nbu_range_body("USD", { "23.01.2026" => 40.0 }))

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rates(from: "UAH", to: "USD", start_date: date, end_date: date)

    assert response.success?
    assert_equal 0.025, response.data.first.rate.to_f
  end

  test "fetch_exchange_rates uses the per-unit rate for currencies quoted in multiples" do
    date = Date.parse("2026-01-23")

    # NBU quotes JPY per 10 units: 2.7 UAH per 10 JPY is 0.27 UAH per 1 JPY
    mock_response = mock
    mock_response.stubs(:body).returns(nbu_range_body("JPY", { "23.01.2026" => 2.7 }, units: 10))

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rates(from: "JPY", to: "UAH", start_date: date, end_date: date)

    assert response.success?
    assert_equal 0.27, response.data.first.rate.to_f
  end

  test "fetch_exchange_rates fails when the range has no rates" do
    date = Date.parse("2026-01-23")

    mock_response = mock
    mock_response.stubs(:body).returns("[]")

    mock_client = mock
    mock_client.stubs(:get).returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rates(from: "USD", to: "UAH", start_date: date, end_date: date)

    assert_not response.success?
    assert_instance_of Provider::Nbu::InvalidExchangeRateError, response.error
  end

  test "fetch_exchange_rates returns 1.0 for UAH to UAH range" do
    start_date = Date.parse("2026-01-23")
    end_date = Date.parse("2026-01-25")

    response = @provider.fetch_exchange_rates(from: "UAH", to: "UAH", start_date: start_date, end_date: end_date)

    assert response.success?
    rates = response.data
    assert_equal 3, rates.length
    assert rates.all? { |r| r.rate == 1.0 }
    assert rates.all? { |r| r.from == "UAH" && r.to == "UAH" }
  end

  test "fetch_exchange_rates delegates to fallback for non-UAH pairs" do
    start_date = Date.parse("2026-01-23")
    end_date = Date.parse("2026-01-25")

    # Mock the fallback provider (Yahoo Finance)
    mock_fallback = mock
    expected_rates = [
      Provider::ExchangeRateConcept::Rate.new(date: start_date, from: "USD", to: "EUR", rate: 0.92),
      Provider::ExchangeRateConcept::Rate.new(date: end_date, from: "USD", to: "EUR", rate: 0.93)
    ]
    mock_fallback.expects(:fetch_exchange_rates).with(
      from: "USD", to: "EUR", start_date: start_date, end_date: end_date
    ).returns(Provider::Response.new(success?: true, data: expected_rates, error: nil))
    @provider.instance_variable_set(:@fallback_provider, mock_fallback)

    response = @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 2, response.data.length
  end

  test "fetch_exchange_rates validates date range" do
    response = @provider.fetch_exchange_rates(
      from: "USD",
      to: "UAH",
      start_date: Date.current,
      end_date: Date.current - 1.day
    )
    assert_not response.success?
    assert_instance_of Provider::Nbu::Error, response.error
    assert_match(/Start date cannot be after end date/, response.error.message)
  end

  test "fetch_exchange_rates asks for a range longer than a year one year at a time" do
    start_date = Date.parse("2024-11-15")
    end_date = Date.parse("2026-11-16") # two years and a day: three requests

    requested = []
    bodies = [
      nbu_range_body("EUR", { "15.11.2024" => 43.5, "14.11.2025" => 48.0 }),
      nbu_range_body("EUR", { "15.11.2025" => 48.1, "14.11.2026" => 50.2 }),
      nbu_range_body("EUR", { "15.11.2026" => 50.3, "16.11.2026" => 50.4 })
    ]
    mock_client = Object.new
    mock_client.define_singleton_method(:get) do |_url, &block|
      request = Struct.new(:params).new({})
      block.call(request)
      requested << request.params.slice("start", "end")
      Struct.new(:body).new(bodies.shift)
    end
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_exchange_rates(from: "EUR", to: "UAH", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal [ { "start" => "20241115", "end" => "20251114" }, { "start" => "20251115", "end" => "20261114" },
                   { "start" => "20261115", "end" => "20261116" } ], requested
    assert_equal %w[2024-11-15 2025-11-14 2025-11-15 2026-11-14 2026-11-15 2026-11-16], response.data.map { |rate| rate.date.iso8601 }
    assert_equal 50.4, response.data.last.rate.to_f
    assert response.data.all? { |rate| rate.from == "EUR" && rate.to == "UAH" }
  end

  # ================================
  #       Error Handling Tests
  # ================================

  test "handles Faraday errors gracefully" do
    faraday_error = Faraday::ConnectionFailed.new("Connection failed")

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(faraday_error)

    result = @provider.fetch_exchange_rate(from: "USD", to: "UAH", date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::Nbu::Error, result.error
  end

  test "handles JSON parse errors" do
    mock_response = mock
    mock_response.stubs(:body).returns("invalid json")

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_exchange_rate(from: "USD", to: "UAH", date: Date.current)

    assert_not result.success?
  end

  # ================================
  #       Helper Method Tests
  # ================================

  test "format_date returns YYYYMMDD format" do
    date = Date.parse("2026-01-25")
    formatted = @provider.send(:format_date, date)
    assert_equal "20260125", formatted
  end

  test "involves_uah? returns true when UAH is from currency" do
    assert @provider.send(:involves_uah?, "UAH", "USD")
  end

  test "involves_uah? returns true when UAH is to currency" do
    assert @provider.send(:involves_uah?, "EUR", "UAH")
  end

  test "involves_uah? returns false for non-UAH pairs" do
    assert_not @provider.send(:involves_uah?, "USD", "EUR")
  end

  private
    # Body in the shape of NBU's range endpoint: one row per day, `rate` quoted per `units`
    def nbu_range_body(currency, rates_by_date, units: 1)
      rates_by_date.map do |date, rate|
        { "exchangedate" => date, "cc" => currency, "rate" => rate, "units" => units, "rate_per_unit" => (rate / units).round(6) }
      end.to_json
    end
end
