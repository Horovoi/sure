require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Below has 3 example scenarios:
  # 1. Original ticker
  # 2. Duplicate ticker on a different exchange (different market price)
  # 3. "Offline" version of the same ticker (for users not connected to a provider)
  test "can have duplicate tickers if exchange is different" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.create!(ticker: "TEST", exchange_operating_mic: "CBOE")
    offline = Security.create!(ticker: "TEST", exchange_operating_mic: nil)

    assert original.valid?
    assert duplicate.valid?
    assert offline.valid?
  end

  test "cannot have duplicate tickers if exchange is the same" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: "XNAS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "cannot have duplicate tickers if exchange is nil" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: nil)
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: nil)

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "casing is ignored when checking for duplicates" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "tEst", exchange_operating_mic: "xNaS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "only online and degraded securities are fetchable" do
    statuses = %w[online degraded unavailable manual]
    securities = statuses.map { |status| Security.create!(ticker: "S#{status}", status: status) }

    assert_equal [ true, true, false, false ], securities.map(&:fetchable?)
    assert_equal %w[SDEGRADED SONLINE], Security.fetchable.where(id: securities).pluck(:ticker).sort
    assert_equal [ false, false, true, true ], securities.map(&:offline)
  end

  test "manual and unavailable securities are never fetched from the provider" do
    provider = mock
    Security.stubs(:provider).returns(provider)
    provider.expects(:fetch_security_price).never
    provider.expects(:fetch_security_prices).never
    provider.expects(:fetch_security_info).never

    %w[manual unavailable].each do |status|
      security = Security.create!(ticker: "S#{status}", status: status)

      assert_nil security.find_or_fetch_price(date: Date.current)
      assert_equal 0, security.import_provider_prices(start_date: 5.days.ago.to_date, end_date: Date.current)
      assert_nil security.import_provider_details
    end
  end

  test "find_or_fetch_price replaces a cached row for the provider's date instead of failing" do
    security = Security.create!(ticker: "WKND", exchange_operating_mic: "XNAS")
    friday = Date.new(2026, 11, 13)
    saturday = friday + 1.day
    # A provisional gap-fill for Friday with a stale value
    Security::Price.create!(security: security, date: friday, price: 90, currency: "USD", provisional: true)

    provider = mock
    Security.stubs(:provider).returns(provider)
    provider.expects(:fetch_security_price)
            .with(symbol: "WKND", exchange_operating_mic: "XNAS", date: saturday)
            .returns(provider_success_response(
              Provider::SecurityConcept::Price.new(symbol: "WKND", date: friday, price: 100, currency: "USD", exchange_operating_mic: "XNAS")
            ))

    price = security.find_or_fetch_price(date: saturday)

    assert_equal 100, price.price
    cached = security.prices.find_by!(date: friday)
    assert_equal 100, cached.price
    refute cached.provisional
  end
end
