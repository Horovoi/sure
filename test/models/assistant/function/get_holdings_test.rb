require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetHoldings.new(@user)
    @account = accounts(:investment)
    # The fixtures hold only AAPL, so a second ticker on the same account is what tells a filter from no filter
    @account.holdings.create!(security: securities(:msft), date: Date.current, qty: 3, price: 400, amount: 1200, currency: "USD")
  end

  test "get_holdings filters by security ticker" do
    assert_equal [ "AAPL" ], tickers("securities" => [ "AAPL" ])
    assert_equal [ "MSFT" ], tickers("securities" => [ "MSFT" ])
    assert_equal 1, @fn.call("page" => 1, "securities" => [ "MSFT" ])[:total_results]
  end

  test "get_holdings security filter for a ticker nobody holds returns nothing" do
    assert_empty tickers("securities" => [ "NOPE" ])
  end

  test "get_holdings security filter stays inside the family's visible accounts" do
    @account.update!(status: "disabled")

    assert_empty tickers("securities" => [ "AAPL" ])
  end

  test "get_holdings without a security filter is unchanged" do
    assert_equal [ "AAPL", "MSFT" ], tickers({})
  end

  test "get_holdings normalises an invalid page to the first one" do
    assert_equal 1, @fn.call("page" => 0)[:page]
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "holdings of an account excluded from reports are listed with a flag" do
    @account.update!(exclude_from_reports: true)

    rows = @fn.call("page" => 1)[:holdings]

    assert rows.any?
    assert(rows.all? { |row| row[:account_excluded_from_reports] == true })
  end

  test "total_value converts each holding into the family currency, not at 1" do
    family = @user.family
    @account.holdings.where(security: securities(:msft)).update_all(currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: family.currency, date: Date.current, rate: 2)

    result = @fn.call("page" => 1)
    expected = result[:holdings].sum { |row| row[:currency] == "EUR" ? row[:amount] * 2 : row[:amount] }

    assert_includes result[:holdings].map { |row| row[:currency] }, "EUR"
    assert_equal Money.new(expected, family.currency).format, result[:total_value]
  end

  private
    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
