require "test_helper"

class Holding::PortfolioCacheTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @provider = mock
    Security.stubs(:provider).returns(@provider)

    @account = families(:empty).accounts.create!(
      name: "Test Brokerage",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )

    @security = Security.create!(name: "Test Security", ticker: "TEST", exchange_operating_mic: "TEST")

    @trade = create_trade(@security, account: @account, qty: 1, date: 2.days.ago.to_date, price: 210.23).trade
  end

  test "gets price from DB if available" do
    db_price = 210

    Security::Price.create!(
      security: @security,
      date: Date.current,
      price: db_price
    )

    cache = Holding::PortfolioCache.new(@account)
    assert_equal db_price, cache.get_price(@security.id, Date.current).price
  end

  test "if no price from db, try getting the price from trades" do
    Security::Price.destroy_all

    cache = Holding::PortfolioCache.new(@account)
    assert_equal @trade.price, cache.get_price(@security.id, @trade.entry.date).price
  end

  test "if no price from db or trades, search holdings" do
    Security::Price.delete_all
    Entry.delete_all

    holding = Holding.create!(
      security: @security,
      account: @account,
      date: Date.current,
      qty: 1,
      price: 250,
      amount: 250 * 1,
      currency: "USD"
    )

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)
    assert_equal holding.price, cache.get_price(@security.id, holding.date).price
  end

  test "converts each price at its own date's rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = uah_account_with_usd_trade

    first_day = 2.days.ago.to_date
    second_day = 1.day.ago.to_date
    Security::Price.create!(security: @security, date: first_day, price: 100, currency: "USD")
    Security::Price.create!(security: @security, date: second_day, price: 100, currency: "USD")
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: first_day, rate: 41)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: second_day, rate: 42)

    cache = Holding::PortfolioCache.new(account)

    assert_equal 4100, cache.get_price(@security.id, first_day).price
    assert_equal 4200, cache.get_price(@security.id, second_day).price
    assert_equal "UAH", cache.get_price(@security.id, second_day).currency
  end

  test "a day without a stored rate uses the latest earlier one" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = uah_account_with_usd_trade

    Security::Price.create!(security: @security, date: 1.day.ago.to_date, price: 100, currency: "USD")
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 5.days.ago.to_date, rate: 40)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 45)

    cache = Holding::PortfolioCache.new(account)

    assert_equal 4000, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  test "a price with no rate at all is kept at 1:1 and reported once" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = uah_account_with_usd_trade
    Security::Price.create!(security: @security, date: 1.day.ago.to_date, price: 100, currency: "USD")
    Security::Price.create!(security: @security, date: Date.current, price: 101, currency: "USD")

    cache = Holding::PortfolioCache.new(account)

    assert_equal 100, cache.get_price(@security.id, 1.day.ago.to_date).price
    assert_equal 101, cache.get_price(@security.id, Date.current).price

    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", source: "Test").count }, 1 do
      cache.report_unconverted(source: "Test")
    end

    entry = DebugLogEntry.where(source: "Test").last
    assert_equal 2, entry.metadata["prices_kept_at_parity"]
    assert_equal "USD", entry.metadata["pairs"].first["from"]
  end

  test "a trade price converts at the trade date and is nil with no rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = uah_account_with_usd_trade
    trade = account.trades.first

    cache = Holding::PortfolioCache.new(account)
    assert_nil cache.trade_price_in_account_currency(trade, trade.entry.date)

    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: trade.entry.date, rate: 41)
    assert_equal trade.price * 41, Holding::PortfolioCache.new(account).trade_price_in_account_currency(trade, trade.entry.date)
  end

  private
    def uah_account_with_usd_trade
      account = families(:empty).accounts.create!(name: "UAH Brokerage", balance: 0, currency: "UAH", accountable: Investment.new)
      create_trade(@security, account: account, qty: 1, date: 3.days.ago.to_date, price: 100, currency: "USD")
      account
    end
end
