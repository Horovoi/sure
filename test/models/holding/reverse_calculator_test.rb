require "test_helper"

class Holding::ReverseCalculatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Test",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "no holdings" do
    empty_snapshot = OpenStruct.new(to_h: {})
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: empty_snapshot).calculate
    assert_equal [], calculated
  end

  test "holding generation respects user timezone and last generated date is current user date" do
    # Simulate user in EST timezone
    Time.use_zone("America/New_York") do
      # Set current time to 1am UTC on Jan 5, 2025
      # This would be 8pm EST on Jan 4, 2025 (user's time, and the last date we should generate holdings for)
      travel_to Time.utc(2025, 01, 05, 1, 0, 0)

      voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
      Security::Price.create!(security: voo, date: "2025-01-02", price: 500)
      Security::Price.create!(security: voo, date: "2025-01-03", price: 500)
      Security::Price.create!(security: voo, date: "2025-01-04", price: 500)

      # Today's holdings (provided)
      @account.holdings.create!(security: voo, date: "2025-01-04", qty: 10, price: 500, amount: 5000, currency: "USD")

      create_trade(voo, qty: 10, date: "2025-01-03", price: 500, account: @account)

      expected = [ [ "2025-01-02", 0 ], [ "2025-01-03", 5000 ], [ "2025-01-04", 5000 ] ]
      # Mock snapshot with the holdings we created
      snapshot = OpenStruct.new(to_h: { voo.id => 10 })
      calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

      assert_equal expected, calculated.sort_by(&:date).map { |b| [ b.date.to_s, b.amount ] }
    end
  end

  # Should be able to handle this case, although we should not be reverse-syncing an account without provided current day holdings
  test "reverse portfolio with trades but without current day holdings" do
    voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
    Security::Price.create!(security: voo, date: Date.current, price: 470)
    Security::Price.create!(security: voo, date: 1.day.ago.to_date, price: 470)

    create_trade(voo, qty: -10, date: Date.current, price: 470, account: @account)

    # Mock empty portfolio since no current day holdings
    snapshot = OpenStruct.new(to_h: { voo.id => 0 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate
    assert_equal 2, calculated.length
  end

  test "reverse portfolio calculation" do
    load_today_portfolio

    # Build up to 10 shares of VOO (current value $5000)
    create_trade(@voo, qty: 20, date: 3.days.ago.to_date, price: 470, account: @account)
    create_trade(@voo, qty: -15, date: 2.days.ago.to_date, price: 480, account: @account)
    create_trade(@voo, qty: 5, date: 1.day.ago.to_date, price: 490, account: @account)

    # Amazon won't exist in current holdings because qty is zero, but should show up in historical portfolio
    create_trade(@amzn, qty: 1, date: 2.days.ago.to_date, price: 200, account: @account)
    create_trade(@amzn, qty: -1, date: 1.day.ago.to_date, price: 200, account: @account)

    # Build up to 100 shares of WMT (current value $10000)
    create_trade(@wmt, qty: 100, date: 1.day.ago.to_date, price: 100, account: @account)

    expected = [
      # 4 days ago
      Holding.new(security: @voo, date: 4.days.ago.to_date, qty: 0, price: 460, amount: 0),
      Holding.new(security: @wmt, date: 4.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 4.days.ago.to_date, qty: 0, price: 200, amount: 0),

      # 3 days ago
      Holding.new(security: @voo, date: 3.days.ago.to_date, qty: 20, price: 470, amount: 9400),
      Holding.new(security: @wmt, date: 3.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 3.days.ago.to_date, qty: 0, price: 200, amount: 0),

      # 2 days ago
      Holding.new(security: @voo, date: 2.days.ago.to_date, qty: 5, price: 480, amount: 2400),
      Holding.new(security: @wmt, date: 2.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 2.days.ago.to_date, qty: 1, price: 200, amount: 200),

      # 1 day ago
      Holding.new(security: @voo, date: 1.day.ago.to_date, qty: 10, price: 490, amount: 4900),
      Holding.new(security: @wmt, date: 1.day.ago.to_date, qty: 100, price: 100, amount: 10000),
      Holding.new(security: @amzn, date: 1.day.ago.to_date, qty: 0, price: 200, amount: 0),

      # Today
      Holding.new(security: @voo, date: Date.current, qty: 10, price: 500, amount: 5000),
      Holding.new(security: @wmt, date: Date.current, qty: 100, price: 100, amount: 10000),
      Holding.new(security: @amzn, date: Date.current, qty: 0, price: 200, amount: 0)
    ]

    # Mock snapshot with today's portfolio from load_today_portfolio
    snapshot = OpenStruct.new(to_h: { @voo.id => 10, @wmt.id => 100, @amzn.id => 0 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert_equal expected.length, calculated.length

    expected.each do |expected_entry|
      calculated_entry = calculated.find { |c| c.security == expected_entry.security && c.date == expected_entry.date }

      assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
      assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
      assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
    end
  end

  # For a reverse sync, Plaid will provide today's holdings + prices.  We need to match those exactly so balances match in net worth rollups.
  test "current day holdings always match provided holdings and prices" do
    # Provider gives us total value of $10,000 ($5,000 cash, $5,000 in holdings)
    @account.update!(balance: 10000, cash_balance: 5000)

    wmt = Security.create!(ticker: "WMT", name: "Walmart Inc.")
    create_trade(wmt, qty: 50, date: 1.day.ago.to_date, price: 98, account: @account)

    @account.holdings.create!(
      date: Date.current,
      price: 100,
      qty: 50,
      amount: 5000,
      currency: "USD",
      security: wmt
    )

    Security::Price.create!(security: wmt, date: Date.current, price: 102) # This price should be ignored on current day
    Security::Price.create!(security: wmt, date: 1.day.ago, price: 98) # This price will be used for historical holding calculation
    Security::Price.create!(security: wmt, date: 2.days.ago, price: 95) # This price will be used for historical holding calculation

    expected = [
      Holding.new(security: wmt, date: 2.days.ago.to_date, qty: 0, price: 95, amount: 0), # Uses market price, empty holding
      Holding.new(security: wmt, date: 1.day.ago.to_date, qty: 50, price: 98, amount: 4900), # Uses market price
      Holding.new(security: wmt, date: Date.current, qty: 50, price: 100, amount: 5000) # Uses holding price, not market price
    ]

    # Mock snapshot with WMT holding from the test setup
    snapshot = OpenStruct.new(to_h: { wmt.id => 50 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert_equal expected.length, calculated.length

    expected.each do |expected_entry|
      calculated_entry = calculated.find { |c| c.security == expected_entry.security && c.date == expected_entry.date }

      assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
      assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
      assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
    end
  end


  test "USD-priced security in a UAH account converts each purchase at its own date" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = families(:empty).accounts.create!(name: "UAH", balance: 0, cash_balance: 0, currency: "UAH", accountable: Investment.new)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")

    first_day = 3.days.ago.to_date
    second_day = 2.days.ago.to_date
    first_day.upto(Date.current) { |date| Security::Price.create!(security: aapl, date: date, price: 100, currency: "USD") }
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: first_day, rate: 40)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: second_day, rate: 42)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 45)
    account.holdings.create!(security: aapl, date: Date.current, qty: 20, price: 4_500, amount: 90_000, currency: "UAH")

    create_trade(aapl, qty: 10, date: first_day, price: 100, currency: "USD", account: account)
    create_trade(aapl, qty: 10, date: second_day, price: 100, currency: "USD", account: account)

    snapshot = OpenStruct.new(to_h: { aapl.id => 20 })
    calculated = Holding::ReverseCalculator.new(account, portfolio_snapshot: snapshot).calculate
    by_date = calculated.index_by(&:date)

    assert_equal 4_000, by_date[first_day].cost_basis
    assert_equal 4_100, by_date[1.day.ago.to_date].cost_basis
    # A historical price converts at its own date
    assert_equal 84_000, by_date[second_day].amount
  end

  test "a purchase with no exchange rate leaves the cost basis unknown" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = families(:empty).accounts.create!(name: "UAH", balance: 0, cash_balance: 0, currency: "UAH", accountable: Investment.new)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")

    trade_day = 2.days.ago.to_date
    trade_day.upto(Date.current) { |date| Security::Price.create!(security: aapl, date: date, price: 100, currency: "USD") }
    create_trade(aapl, qty: 10, date: trade_day, price: 100, currency: "USD", account: account)

    snapshot = OpenStruct.new(to_h: { aapl.id => 10 })
    calculated = Holding::ReverseCalculator.new(account, portfolio_snapshot: snapshot).calculate

    after_trade = calculated.select { |h| h.date >= trade_day }
    assert after_trade.any?
    assert after_trade.all? { |h| h.cost_basis.nil? }
  end


  test "returns holding data structs, gap-filled days included" do
    voo = Security.create!(ticker: "VOO#{SecureRandom.hex(2)}", name: "Vanguard S&P 500 ETF")
    # No price yesterday: that day is gap-filled from the day before
    Security::Price.create!(security: voo, date: 2.days.ago.to_date, price: 490)
    @account.holdings.create!(security: voo, date: Date.current, qty: 3, price: 500, amount: 1_500, currency: "USD")
    create_trade(voo, qty: 3, date: 2.days.ago.to_date, price: 490, account: @account)

    snapshot = OpenStruct.new(to_h: { voo.id => 3 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert calculated.all? { |h| h.is_a?(Holding::HoldingData) }
    filled = calculated.find { |h| h.date == 1.day.ago.to_date }
    assert_not_nil filled
    assert_equal 490, filled.price
    assert_equal 490, filled.cost_basis
  end

  # --- Weighted-average cost basis and transfers (w2-transfers wac-cost-basis) ---

  test "a partial sell then a buy averages only the units still held" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")

    calc = calculator_with_trades(security, snapshot_qty: 10) do
      create_trade(security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
      create_trade(security, account: @account, qty: -5, price: 130, date: 6.days.ago.to_date)
      create_trade(security, account: @account, qty: 5, price: 200, date: 3.days.ago.to_date)
    end

    assert_equal BigDecimal("100"), cost_basis_for(calc, security, 6.days.ago.to_date)
    # (5 x 100 + 5 x 200) / 10
    assert_equal BigDecimal("150"), cost_basis_for(calc, security, Date.current)
  end

  test "the basis is nil while fully sold and starts again after a repurchase" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")
    rebuy_date = 3.days.ago.to_date

    calc = calculator_with_trades(security, snapshot_qty: 10) do
      create_trade(security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
      create_trade(security, account: @account, qty: -10, price: 130, date: 6.days.ago.to_date)
      create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
    end

    assert_nil cost_basis_for(calc, security, 6.days.ago.to_date)
    assert_nil cost_basis_for(calc, security, rebuy_date - 1)
    assert_equal BigDecimal("150"), cost_basis_for(calc, security, Date.current)
  end

  test "a transfer out relieves the units and keeps the basis known" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")

    calc = calculator_with_trades(security, snapshot_qty: 10) do
      create_trade(security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
      transfer_out = create_trade(security, account: @account, qty: -10, price: 120, date: 6.days.ago.to_date)
      transfer_out.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      create_trade(security, account: @account, qty: 10, price: 150, date: 3.days.ago.to_date)
    end

    assert_equal BigDecimal("150"), cost_basis_for(calc, security, Date.current)
    assert_not calc.send(:cost_basis_unknown?, security.id, Date.current)
  end

  test "a transfer in makes the basis unknown from its date, and a close releases it" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")
    buy_date = 12.days.ago.to_date
    transfer_date = 9.days.ago.to_date
    close_date = 6.days.ago.to_date
    rebuy_date = 3.days.ago.to_date

    # Trades net to 10, the snapshot's quantity, so the position really reaches zero
    calc = calculator_with_trades(security, snapshot_qty: 10) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      create_trade(security, account: @account, qty: -15, price: 130, date: close_date)
      create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
    end

    assert_equal BigDecimal("100"), cost_basis_for(calc, security, transfer_date - 1)
    assert_nil cost_basis_for(calc, security, transfer_date)
    assert calc.send(:cost_basis_unknown?, security.id, transfer_date)
    assert_nil cost_basis_for(calc, security, close_date - 1)
    assert_equal BigDecimal("150"), cost_basis_for(calc, security, rebuy_date)
    assert_not calc.send(:cost_basis_unknown?, security.id, Date.current)
  end

  test "a transferred position stays unknown when opening shares keep it from closing" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")

    # The snapshot is 10 but the trades net to 8: two shares predate the history
    calc = calculator_with_trades(security, snapshot_qty: 10) do
      create_trade(security, account: @account, qty: 10, price: 100, date: 12.days.ago.to_date)
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: 9.days.ago.to_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      create_trade(security, account: @account, qty: -15, price: 130, date: 6.days.ago.to_date)
      create_trade(security, account: @account, qty: 8, price: 150, date: 3.days.ago.to_date)
    end

    assert_nil cost_basis_for(calc, security, Date.current)
    assert calc.send(:cost_basis_unknown?, security.id, Date.current)
  end

  test "a transferred position stays unknown when a gapped import gives a negative baseline" do
    security = Security.create!(ticker: "TST#{SecureRandom.hex(2)}", name: "Test")

    # The trades net to +10 but the snapshot holds 0, so the seeded baseline is -10
    calc = calculator_with_trades(security, snapshot_qty: 0) do
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: 9.days.ago.to_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      create_trade(security, account: @account, qty: 5, price: 150, date: 5.days.ago.to_date)
    end

    assert_nil cost_basis_for(calc, security, 9.days.ago.to_date)
    assert_nil cost_basis_for(calc, security, Date.current)
  end

  private
    def calculator_with_trades(security, snapshot_qty:)
      yield
      snapshot = OpenStruct.new(to_h: { security.id => snapshot_qty })
      calc = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot)
      calc.send(:precompute_cost_basis)
      calc
    end

    def cost_basis_for(calc, security, date)
      calc.send(:cost_basis_for, security.id, date)
    end

    def assert_holdings(expected, calculated)
      expected.each do |expected_entry|
        calculated_entry = calculated.find { |c| c.security == expected_entry.security && c.date == expected_entry.date }

        assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
        assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
        assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for #{expected_entry.security.ticker} on #{expected_entry.date}"
      end
    end

    def load_prices
      @voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
      Security::Price.create!(security: @voo, date: 4.days.ago.to_date, price: 460)
      Security::Price.create!(security: @voo, date: 3.days.ago.to_date, price: 470)
      Security::Price.create!(security: @voo, date: 2.days.ago.to_date, price: 480)
      Security::Price.create!(security: @voo, date: 1.day.ago.to_date, price: 490)
      Security::Price.create!(security: @voo, date: Date.current, price: 500)

      @wmt = Security.create!(ticker: "WMT", name: "Walmart Inc.")
      Security::Price.create!(security: @wmt, date: 4.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 3.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 2.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 1.day.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: Date.current, price: 100)

      @amzn = Security.create!(ticker: "AMZN", name: "Amazon.com Inc.")
      Security::Price.create!(security: @amzn, date: 4.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 3.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 2.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 1.day.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: Date.current, price: 200)
    end

    # Portfolio holdings:
    # +--------+-----+--------+---------+
    # | Ticker | Qty | Price  | Amount  |
    # +--------+-----+--------+---------+
    # | VOO    |  10 | $500   | $5,000  |
    # | WMT    | 100 | $100   | $10,000 |
    # +--------+-----+--------+---------+
    # Brokerage Cash: $5,000
    # Holdings Value: $15,000
    # Total Balance: $20,000
    def load_today_portfolio
      @account.update!(cash_balance: 5000)

      load_prices

      @account.holdings.create!(
        date: Date.current,
        price: 500,
        qty: 10,
        amount: 5000,
        currency: "USD",
        security: @voo
      )

      @account.holdings.create!(
        date: Date.current,
        price: 100,
        qty: 100,
        amount: 10000,
        currency: "USD",
        security: @wmt
      )
    end
end
