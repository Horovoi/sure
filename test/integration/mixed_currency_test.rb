require "test_helper"

# Every other fixture is USD, so the suite never combines two currencies and Money's
# currency guard would find nothing. This family is set up like the owner's: UAH family
# currency, a USD and an EUR account next to UAH ones, and a security priced in USD. Each
# path below must convert before it adds, subtracts or compares.
#
# Strict mode is off here on purpose: syncs rescue errors broadly, which would swallow a
# raised mismatch. In report mode every mismatch reaches Rails.error, so the tests assert
# that none was reported.
class MixedCurrencyTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @strict_currency = Money.strict_currency?
    Money.strict_currency = false
    Money.reset_reported_mismatches!

    @user = users(:family_admin)
    @family = @user.family

    @family.update_columns(currency: "UAH")
    switch_currency(accounts(:depository), "UAH")
    switch_currency(accounts(:credit_card), "UAH")
    switch_currency(accounts(:investment), "USD")
    switch_currency(accounts(:other_asset), "EUR")

    rates = {
      %w[USD UAH] => 41.5, %w[UAH USD] => 0.0241, %w[EUR UAH] => 45.2, %w[UAH EUR] => 0.0221,
      %w[EUR USD] => 1.09, %w[USD EUR] => 0.92
    }
    rows = ((Date.current - 2.years)..Date.current).flat_map do |date|
      rates.map { |(from, to), rate| { from_currency: from, to_currency: to, date: date, rate: rate } }
    end
    ExchangeRate.upsert_all(rows, unique_by: %i[from_currency to_currency date])

    @family.recurring_transactions.create!(
      merchant: merchants(:netflix), amount: 15.99, currency: "USD", expected_day_of_month: 5,
      last_occurrence_date: Date.current, next_expected_date: 1.month.from_now, status: "active",
      subscription_state: "subscription", billing_cycle: "monthly", default_account: accounts(:depository)
    )
    @family.recurring_transactions.create!(
      merchant: merchants(:amazon), amount: 120, currency: "EUR", expected_day_of_month: 10,
      last_occurrence_date: Date.current, next_expected_date: 1.year.from_now, status: "active",
      subscription_state: "subscription", billing_cycle: "yearly"
    )
  end

  teardown do
    Money.strict_currency = @strict_currency
    Money.reset_reported_mismatches!
  end

  test "syncs and transfer matching convert before combining amounts" do
    create_transaction(account: accounts(:depository), amount: 4150, currency: "UAH", date: 2.days.ago.to_date)
    create_transaction(account: accounts(:investment), amount: -100, currency: "USD", date: 2.days.ago.to_date)

    assert_no_currency_mismatch do
      @family.accounts.each do |account|
        syncer = Account::Syncer.new(account)
        syncer.perform_sync(Sync.create!(syncable: account))
        syncer.perform_post_sync
      end
      @family.auto_match_transfers!
    end
  end

  test "assistant read functions convert before combining amounts" do
    calls = {
      Assistant::Function::GetAccounts => {},
      Assistant::Function::GetBalanceSheet => {},
      Assistant::Function::GetHoldings => { "page" => 1 },
      Assistant::Function::GetIncomeStatement => { "start_date" => 1.year.ago.to_date.iso8601, "end_date" => Date.current.iso8601 },
      Assistant::Function::GetTransactions => { "page" => 1 }
    }

    assert_no_currency_mismatch do
      calls.each do |function, params|
        result = function.new(@user).call(params)
        assert_not result.is_a?(Hash) && result.with_indifferent_access[:error].present?, "#{function.name.demodulize} returned an error"
      end
    end
  end

  test "pages convert before combining amounts" do
    sign_in @user

    paths = %w[/ /accounts /transactions /reports /reports?period_type=quarterly /subscriptions /subscriptions/calendar /budgets]
    paths += @family.accounts.map { |account| account_path(account) }

    assert_no_currency_mismatch do
      paths.each do |path|
        get path
        follow_redirect! while response.redirect?
        assert_response :success, "GET #{path}"
      end
    end
  end

  test "the probe sees a mismatch in report mode" do
    reports = capture_error_reports(Money::CurrencyMismatchError) { Money.new(200, :usd) - Money.new(180, :eur) }

    assert_equal 1, reports.size, "the probe must be able to see a mismatch, or the tests above prove nothing"
  end

  private
    def switch_currency(account, currency)
      account.update_columns(currency: currency)
      account.entries.update_all(currency: currency)
      account.balances.update_all(currency: currency)
      account.holdings.update_all(currency: currency)
    end

    def assert_no_currency_mismatch(&block)
      reports = capture_error_reports(Money::CurrencyMismatchError, &block)
      assert_empty reports.map { |report| "#{report.error.message} at #{report.context[:call_site]}" }
    end
end
