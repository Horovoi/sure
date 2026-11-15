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

    # The family already has a USD Netflix subscription (fixture); a second one with the same merchant,
    # amount and currency would break idx_recurring_txns_merchant
    recurring_transactions(:netflix_subscription).update!(
      expected_day_of_month: 5, last_occurrence_date: Date.current, next_expected_date: 1.month.from_now,
      status: "active", subscription_state: "subscription", billing_cycle: "monthly", default_account: accounts(:depository)
    )
    @family.recurring_transactions.create!(
      merchant: merchants(:amazon), amount: 120, currency: "EUR", expected_day_of_month: 10,
      last_occurrence_date: Date.current, next_expected_date: 1.year.from_now, status: "active",
      subscription_state: "subscription", billing_cycle: "yearly", expected_month: 1.year.from_now.month
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
    uah_spend = create_transaction(account: accounts(:depository), amount: 4150, currency: "UAH", date: 2.days.ago.to_date)
    create_transaction(account: accounts(:investment), amount: -100, currency: "USD", date: 2.days.ago.to_date)
    period = { "start_date" => 1.year.ago.to_date.iso8601, "end_date" => Date.current.iso8601 }

    # Every read tool the chat and MCP serve (Assistant.function_classes_for(:read)), with arguments that make it
    # combine amounts. A new read tool must be added here, so it is checked too.
    calls = {
      Assistant::Function::GetAccounts => { "include_balance_series" => true },
      Assistant::Function::GetBalanceSheet => {},
      Assistant::Function::GetIncomeStatement => period.merge("group_by" => "month", "compare_previous_period" => true),
      Assistant::Function::GetTransactions => { "page" => 1 },
      Assistant::Function::GetHoldings => { "page" => 1 },
      Assistant::Function::GetValuations => {},
      Assistant::Function::GetCategories => {},
      Assistant::Function::GetTags => {},
      Assistant::Function::GetMerchants => {},
      Assistant::Function::GetUncategorizedTransactions => period,
      Assistant::Function::GetSubscriptions => { "filter" => "all" },
      Assistant::Function::GetBudget => {},
      Assistant::Function::GetRules => {},
      Assistant::Function::GetRuleOptions => {},
      Assistant::Function::PreviewRule => {
        "conditions" => [ { "condition_type" => "transaction_amount", "operator" => ">", "value" => "0" } ],
        "actions" => [ { "action_type" => "set_transaction_category", "value" => categories(:food_and_drink).id } ]
      },
      Assistant::Function::GetTransferMatchCandidates => { "transaction_id" => uah_spend.entryable.id }
    }
    # search_family_files reads the vector store of the AI provider and sums no amounts
    not_checked = [ Assistant::Function::SearchFamilyFiles ]

    assert_equal (Assistant.function_classes_for(:read) - not_checked).map(&:name).sort, calls.keys.map(&:name).sort

    assert_no_currency_mismatch do
      calls.each do |function, params|
        result = function.new(@user).call(params)
        assert_not result.is_a?(Hash) && result.with_indifferent_access[:error].present?, "#{function.name.demodulize} returned an error: #{result.inspect.truncate(300)}"
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
