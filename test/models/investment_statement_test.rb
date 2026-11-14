require "test_helper"

class InvestmentStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.update!(currency: "USD")
    @statement = InvestmentStatement.new(@family)

    @usd_account = @family.accounts.create!(name: "USD brokerage", balance: 1000, cash_balance: 200, currency: "USD", accountable: Investment.new)
    @eur_account = @family.accounts.create!(name: "EUR brokerage", balance: 500, cash_balance: 100, currency: "EUR", accountable: Investment.new)

    # The latest rate on or before today is used, even when today's is missing
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 3.days.ago.to_date, rate: 1.1)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 1.day.ago.to_date, rate: 1.2)
  end

  test "portfolio value and cash are converted to the family currency" do
    assert_equal 1000 + 500 * 1.2, @statement.portfolio_value
    assert_equal 200 + 100 * 1.2, @statement.cash_balance
    assert_equal Money.new(1600, "USD"), @statement.portfolio_value_money
  end

  test "holdings in another currency are included and converted when summed" do
    security = securities(:aapl)
    Holding.create!(account: @eur_account, security: security, date: Date.current, qty: 10, price: 30, amount: 300, currency: "EUR", cost_basis: 20)
    Holding.create!(account: @usd_account, security: security, date: Date.current, qty: 10, price: 50, amount: 500, currency: "USD", cost_basis: 40)

    assert_equal 2, @statement.current_holdings.count

    # (300 - 200) EUR * 1.2 + (500 - 400) USD
    assert_equal 220, @statement.unrealized_gains

    trend = @statement.unrealized_gains_trend
    assert_equal 300 * 1.2 + 500, trend.current
    assert_equal 200 * 1.2 + 400, trend.previous

    weights = @statement.allocation.map(&:weight)
    assert_equal [ 41.86, 58.14 ].sort, weights.sort
  end

  test "top holdings are ranked by value in the family currency" do
    security = securities(:aapl)
    other = securities(:msft)
    Holding.create!(account: @eur_account, security: security, date: Date.current, qty: 1, price: 450, amount: 450, currency: "EUR")
    Holding.create!(account: @usd_account, security: other, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")

    assert_equal [ @eur_account.id, @usd_account.id ], @statement.top_holdings.map(&:account_id)
  end
end
