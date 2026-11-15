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

    # Rails does this, for every CurrentAttributes class, between requests and between jobs
    ExchangeRate::FetchMemo.reset

    assert_nil ExchangeRate.find_or_fetch_rate(from: "USD", to: "EUR", date: Date.current)
  end

  # --- Nearest-rate rule (decision 19) ---

  test "find_rate uses the latest stored rate before the day before a later one" do
    ExchangeRate.delete_all
    no_provider_rate
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 30.days.ago.to_date, rate: 40)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 3.days.ago.to_date, rate: 41)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 2.days.from_now.to_date, rate: 43)

    assert_equal 41, ExchangeRate.find_rate(from: "USD", to: "UAH", date: Date.current).rate
  end

  test "find_rate uses the earliest later rate when nothing earlier is stored" do
    ExchangeRate.delete_all
    no_provider_rate
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 5.days.from_now.to_date, rate: 42)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 9.days.from_now.to_date, rate: 44)

    assert_equal 42, ExchangeRate.find_rate(from: "USD", to: "UAH", date: Date.current).rate
  end

  test "find_rate returns nil when the pair has no stored rate at all" do
    ExchangeRate.delete_all
    no_provider_rate

    assert_nil ExchangeRate.find_rate(from: "USD", to: "UAH", date: Date.current)
  end

  test "a provider rate of zero is no rate" do
    ExchangeRate.delete_all
    @provider.stubs(:fetch_exchange_rate).returns(
      provider_success_response(OpenStruct.new(from: "USD", to: "UAH", date: Date.current, rate: 0))
    )

    assert_no_difference "ExchangeRate.count" do
      assert_nil ExchangeRate.find_rate(from: "USD", to: "UAH", date: Date.current)
    end
  end

  test "valid_rate? accepts only finite positive numbers" do
    assert ExchangeRate.valid_rate?(1)
    assert ExchangeRate.valid_rate?(BigDecimal("0.0001"))
    assert ExchangeRate.valid_rate?("41.5")
    assert_not ExchangeRate.valid_rate?(0)
    assert_not ExchangeRate.valid_rate?(-1)
    assert_not ExchangeRate.valid_rate?(nil)
    assert_not ExchangeRate.valid_rate?(BigDecimal("NaN"))
    assert_not ExchangeRate.valid_rate?(BigDecimal("Infinity"))
    assert_not ExchangeRate.valid_rate?(Float::INFINITY)
    assert_not ExchangeRate.valid_rate?("not a number")
  end

  test "Money#exchange_to converts at the nearest stored rate and raises without any" do
    ExchangeRate.delete_all
    no_provider_rate

    assert_raises(Money::ConversionError) { Money.new(10, "USD").exchange_to("UAH") }

    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 40.days.ago.to_date, rate: 40)

    assert_equal Money.new(400, "UAH"), Money.new(10, "USD").exchange_to("UAH")
  end

  test "rates_for uses the nearest stored rate of any age and leaves out a currency with none" do
    ExchangeRate.delete_all
    no_provider_rate
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 60.days.ago.to_date, rate: 39)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 10.days.from_now.to_date, rate: 45)

    rates = ExchangeRate.rates_for(%w[USD EUR PLN UAH], to: "UAH", date: Date.current)

    assert_equal({ "UAH" => 1, "USD" => 39, "EUR" => 45 }, rates.transform_values(&:to_i))
  end

  test "rate_sql gives 1 for the same currency, the nearest rate otherwise and NULL without one" do
    ExchangeRate.delete_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 10.days.ago.to_date, rate: 40)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 2.days.ago.to_date, rate: 41)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 3.days.from_now.to_date, rate: 45)

    rate = ->(from, on) do
      ExchangeRate.connection.select_value(
        ExchangeRate.sanitize_sql_array([ "SELECT #{ExchangeRate.rate_sql(from: ':from', to: ':to', on: 'CAST(:on AS date)')}", { from: from, to: "UAH", on: on } ])
      )&.to_d
    end

    assert_equal 1, rate.call("UAH", Date.current)
    assert_equal 41, rate.call("USD", Date.current)
    assert_equal 40, rate.call("USD", 5.days.ago.to_date)
    assert_equal 40, rate.call("USD", 30.days.ago.to_date)
    assert_equal 45, rate.call("EUR", Date.current)
    assert_nil rate.call("PLN", Date.current)
  end

  test "currencies_without_rate names only currencies with no stored rate on any date" do
    ExchangeRate.delete_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 400.days.ago.to_date, rate: 30)

    assert_equal [ "EUR" ], ExchangeRate.currencies_without_rate([ "USD", "EUR", "UAH", nil, "EUR" ], to: "UAH")
  end

  test "stale_rate_dates names a currency whose newest rate is older than the lookback" do
    ExchangeRate.delete_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 2.days.ago.to_date, rate: 41)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 20.days.ago.to_date, rate: 45)
    # A future-dated row must not hide that today's EUR rate is old
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 3.days.from_now.to_date, rate: 46)

    stale = ExchangeRate.stale_rate_dates(%w[USD EUR PLN UAH], to: "UAH")

    assert_equal({ "EUR" => 20.days.ago.to_date }, stale)
  end

  test "convert_or_leave_out returns nil and writes one debug log entry without a rate" do
    ExchangeRate.delete_all
    no_provider_rate
    family = families(:empty)

    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", source: "ExchangeRateTest").count }, 1 do
      assert_nil ExchangeRate.convert_or_leave_out(Money.new(10, "USD"), to: "UAH", date: Date.current, source: "ExchangeRateTest", family: family)
    end

    entry = DebugLogEntry.where(source: "ExchangeRateTest").last
    assert_equal "warn", entry.level
    assert_equal family, entry.family
    assert_equal({ "currency" => "USD", "to_currency" => "UAH", "date" => Date.current.to_s }, entry.metadata)
  end

  test "convert_or_leave_out converts when a rate exists" do
    ExchangeRate.delete_all
    no_provider_rate
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 1.day.ago.to_date, rate: 41)

    assert_no_difference -> { DebugLogEntry.count } do
      assert_equal Money.new(410, "UAH"), ExchangeRate.convert_or_leave_out(Money.new(10, "USD"), to: "UAH", source: "ExchangeRateTest")
    end
  end

  test "conversion_cache_key changes when a rate into the currency is stored" do
    before = ExchangeRate.conversion_cache_key("UAH")

    travel 1.second do
      ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 41)
    end

    assert_not_equal before, ExchangeRate.conversion_cache_key("UAH")
    assert_includes ExchangeRate.conversion_cache_key("UAH"), ExchangeRate::CONVERSION_CACHE_VERSION
  end

  # Cache keys read the newest stored rate on every dashboard, report and transactions
  # render; that read must not scan the whole table
  test "the newest stored rate is read from an index" do
    assert_index_lookup ExchangeRate.select("MAX(updated_at)"), "index_exchange_rates_on_updated_at"
  end

  test "the newest stored rate into a currency is read from an index" do
    assert_index_lookup ExchangeRate.where(to_currency: "UAH").select("MAX(updated_at)"),
      "index_exchange_rates_on_to_currency_and_updated_at"
  end

  private
    def no_provider_rate
      @provider.stubs(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("no rate")))
    end

    # With sequential scans priced out, the planner uses an index whenever one can answer
    # the query; without one it still falls back to a sequential scan
    def assert_index_lookup(relation, index_name)
      plan = ExchangeRate.transaction do
        ExchangeRate.connection.execute("SET LOCAL enable_seqscan = off")
        ExchangeRate.connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
      end
      assert_includes plan, index_name, "expected the query to use #{index_name}:\n#{plan}"
    end
end
