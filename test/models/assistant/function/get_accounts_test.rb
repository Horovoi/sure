require "test_helper"

class Assistant::Function::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetAccounts.new(@user)
  end

  test "has correct name and is not strict" do
    assert_equal "get_accounts", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "returns account ids and omits the balance series by default" do
    result = @fn.call

    assert result[:accounts].any?
    result[:accounts].each do |account|
      assert account[:id].present?
      assert_not account.key?(:historical_balances)
    end
  end

  test "excludes hidden accounts" do
    hidden = accounts(:depository)
    hidden.update!(status: "disabled")

    assert_not_includes @fn.call[:accounts].map { |a| a[:id] }, hidden.id
  end

  test "states linked only for a linked account" do
    rows = @fn.call[:accounts].index_by { |a| a[:id] }

    assert_equal true, rows[accounts(:connected).id][:is_linked]
    assert_not rows[accounts(:depository).id].key?(:is_linked)
    assert_not rows[accounts(:depository).id].key?(:provider)
  end

  test "includes a numeric balance series bounded by the requested period when asked" do
    series = @fn.call("include_balance_series" => true, "series_period" => "last_30_days")[:accounts]
      .find { |a| a[:id] == accounts(:depository).id }[:historical_balances]

    assert series.present?
    assert series[:start_date] >= 30.days.ago.to_date
    assert_equal Date.current, series[:end_date]
    assert_equal "USD", series[:currency]
    assert(series[:values].all? { |v| v.is_a?(Numeric) })
  end

  test "falls back to last_365_days for an unknown series period" do
    series = @fn.call("include_balance_series" => true, "series_period" => "bogus")[:accounts]
      .find { |a| a[:id] == accounts(:depository).id }[:historical_balances]

    assert series[:start_date] >= 366.days.ago.to_date
  end

  test "an account starting beyond the period skips its series without failing the call" do
    future_account = @family.accounts.create!(name: "Future Start Account", balance: 0, currency: "USD", accountable: Depository.new)
    future_account.entries.create!(name: "Scheduled opening deposit", date: 30.days.from_now.to_date, amount: -100,
      currency: "USD", entryable: Transaction.new)

    result = @fn.call("include_balance_series" => true, "series_period" => "last_7_days")
    future_payload = result[:accounts].find { |a| a[:id] == future_account.id }

    assert_not_nil future_payload
    assert_not future_payload.key?(:historical_balances)
    assert(result[:accounts].any? { |a| a.key?(:historical_balances) })
  end

  test "exposes a fixed-rate loan's terms" do
    loan = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }
    terms = loan[:terms]

    assert_equal "Loan", loan[:type]
    assert_equal 3.5, terms[:interest_rate]
    assert_equal 360, terms[:term_months]
    assert_equal "fixed", terms[:rate_type]
    assert terms[:monthly_payment].present?, "a fixed-rate loan has a computable payment"
    assert terms[:monthly_payment_formatted].present?
    assert terms[:original_balance_formatted].present?
  end

  test "a variable-rate loan has no computed monthly payment" do
    accounts(:loan).loan.update!(rate_type: "variable")

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_equal "variable", terms[:rate_type]
    assert_not terms.key?(:monthly_payment)
  end

  test "omits a term the user never entered" do
    accounts(:loan).loan.update!(interest_rate: nil, rate_type: nil, term_months: nil)

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_not terms.key?(:interest_rate)
    assert_not terms.key?(:term_months)
    assert_not terms.key?(:monthly_payment)
  end

  test "exposes a credit card's terms" do
    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:credit_card).id }[:terms]

    assert_equal 18.99, terms[:apr]
    assert_equal 100.0, terms[:minimum_payment]
    assert_equal 95.0, terms[:annual_fee]
    assert_equal 5000.0, terms[:available_credit]
    assert terms[:expiration_date].present?
  end

  test "omits terms for an account type that carries none" do
    payload = @fn.call[:accounts].find { |a| a[:id] == accounts(:depository).id }

    assert_not payload.key?(:terms)
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "an account excluded from reports is listed and says so" do
    excluded = accounts(:depository)
    excluded.update!(exclude_from_reports: true)

    rows = @fn.call[:accounts].index_by { |a| a[:id] }

    assert_equal true, rows.fetch(excluded.id)[:excluded_from_reports]
    assert_not rows.fetch(accounts(:credit_card).id).key?(:excluded_from_reports)
  end
end
