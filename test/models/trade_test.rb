require "test_helper"

class TradeTest < ActiveSupport::TestCase
  test "build_name generates buy trade name" do
    name = Trade.build_name("buy", 10, "AAPL")
    assert_equal "Buy 10.0 shares of AAPL", name
  end

  test "build_name generates sell trade name" do
    name = Trade.build_name("sell", 5, "MSFT")
    assert_equal "Sell 5.0 shares of MSFT", name
  end

  test "build_name handles absolute value for negative quantities" do
    name = Trade.build_name("sell", -5, "GOOGL")
    assert_equal "Sell 5.0 shares of GOOGL", name
  end

  test "build_name handles decimal quantities" do
    name = Trade.build_name("buy", 0.25, "BTC")
    assert_equal "Buy 0.25 shares of BTC", name
  end

  test "price scale is preserved at 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # up to 10 decimal places — should persist exactly
    precise_price = BigDecimal("12.3456789012")
    trade = Trade.create!(
      security: security,
      price: precise_price,
      qty: 10000,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal precise_price, trade.price
  end

  test "price is rounded to 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # over 10 decimal places — will be rounded
    price_with_too_many_decimals = BigDecimal("1.123456789012345")
    trade = Trade.create!(
      security: security,
      price: price_with_too_many_decimals,
      qty: 1,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal BigDecimal("1.1234567890"), trade.price
  end

  # --- Realized gain across currencies (w1-fx securities-fx) ---

  test "realized gain converts the proceeds into the basis currency at the sale date" do
    ExchangeRate.stubs(:provider).returns(nil)
    sale = usd_sale_from_uah_position(sale_date: 3.days.ago.to_date)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 3.days.ago.to_date, rate: 42)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 45)

    gain = sale.realized_gain_loss

    # 2 x 110 USD x 42 = 9 240 UAH of proceeds, less 2 x 4 000 UAH of basis
    assert_equal "UAH", gain.value.currency.iso_code
    assert_equal 1_240, gain.value.amount
    assert_not sale.realized_gain_unconvertible?
  end

  test "realized gain reads the preloaded rate for the sale date" do
    ExchangeRate.stubs(:provider).returns(nil)
    sale = usd_sale_from_uah_position(sale_date: 3.days.ago.to_date)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 3.days.ago.to_date, rate: 42)

    sale.instance_variable_set(:@preloaded_holdings, sale.entry.account.holdings.to_a)
    Trade.preload_exchange_rates([ sale ])

    ExchangeRate.expects(:convert_or_leave_out).never
    assert_equal 1_240, sale.realized_gain_loss.value.amount
  end

  test "realized gain is unknown, not converted at 1, when the pair has no rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    sale = usd_sale_from_uah_position(sale_date: 3.days.ago.to_date)

    assert_nil sale.realized_gain_loss
    assert sale.realized_gain_unconvertible?
  end

  test "realized gain in the basis currency needs no rate" do
    sale = usd_sale_from_uah_position(sale_date: 3.days.ago.to_date, sale_currency: "UAH", sale_price: 4_500)

    assert_equal 1_000, sale.realized_gain_loss.value.amount
    assert_not sale.realized_gain_unconvertible?
  end

  test "a transfer out realizes nothing, however it is priced" do
    account, security = position_with_known_cost_basis

    moved = build_negative_trade(account, security, label: "Transfer")
    sold = build_negative_trade(account, security, label: "Sell")

    assert_nil moved.realized_gain_loss
    assert_not_nil sold.realized_gain_loss
  end

  test "every internal movement label realizes nothing" do
    account, security = position_with_known_cost_basis

    Trade::INTERNAL_MOVEMENT_LABELS.each do |label|
      assert_nil build_negative_trade(account, security, label: label).realized_gain_loss, "#{label} should not realize a gain"
    end
  end

  # On a security "Exchange" can be a security-for-security exchange that disposes of an
  # appreciated asset, so it stays a sale
  test "an exchange is not an internal movement on a trade" do
    assert_not Trade.new(investment_activity_label: "Exchange").internal_movement?
    assert_includes Transaction::INTERNAL_MOVEMENT_LABELS, "Exchange"
    assert_not_includes Trade::INTERNAL_MOVEMENT_LABELS, "Exchange"
  end

  test "transfer and sweep labels are internal movements" do
    [ "Transfer", "Sweep In", "Sweep Out" ].each do |label|
      assert Trade.new(investment_activity_label: label).internal_movement?, label
    end
  end

  private
    def usd_sale_from_uah_position(sale_date:, sale_currency: "USD", sale_price: 110)
      account = families(:empty).accounts.create!(name: "UAH Brokerage", balance: 0, currency: "UAH", accountable: Investment.new)
      security = Security.create!(ticker: "AAPL#{SecureRandom.hex(3)}", name: "Apple")
      account.holdings.create!(security: security, date: sale_date - 1.day, qty: 10, price: 4_000,
                               amount: 40_000, currency: "UAH", cost_basis: 4_000)

      trade = Trade.new(security: security, qty: -2, price: sale_price, currency: sale_currency, investment_activity_label: "Sell")
      account.entries.create!(name: "Sell", date: sale_date, amount: -2 * sale_price, currency: sale_currency, entryable: trade)
      trade
    end

    # A position with a known cost basis: without one realized_gain_loss is nil anyway
    def position_with_known_cost_basis
      account = families(:empty).accounts.create!(name: "Wallet", balance: 100, currency: "USD", accountable: Investment.new)
      security = Security.create!(ticker: "MOVE#{SecureRandom.hex(3)}", name: "Movable")
      Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                      qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

      [ account, security ]
    end

    def build_negative_trade(account, security, label:)
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD", investment_activity_label: label)
      ).entryable
    end
end
