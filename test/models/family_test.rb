require "test_helper"

class FamilyTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  def setup
    @syncable = families(:dylan_family)
  end

  test "available_merchants includes family merchants without transactions" do
    family = families(:dylan_family)

    new_merchant = family.merchants.create!(name: "New Test Merchant")

    assert_includes family.available_merchants, new_merchant
  end

  test "with fiscal start day 31 every budget period starts on the clamped day and ends the day before the next" do
    family = families(:empty)
    family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)

    assert_equal Date.new(2026, 11, 30), family.budget_period_start_for(Date.new(2026, 11, 30))
    assert_equal Date.new(2026, 10, 31), family.budget_period_start_for(Date.new(2026, 11, 29))
    assert_equal Date.new(2027, 2, 28), family.budget_period_start_for(Date.new(2027, 3, 15))
    assert_equal Date.new(2027, 2, 27), family.budget_period_end_for(Date.new(2027, 1, 31))
    assert_equal Date.new(2027, 3, 30), family.budget_period_end_for(Date.new(2027, 2, 28))
    assert_equal Date.new(2026, 11, 29), family.budget_period_end_for(Date.new(2026, 10, 31))
  end

  test "the subscriptions feed is off until enabled" do
    family = families(:dylan_family)

    assert_not family.subscriptions_feed_enabled?
    assert_nil Family.find_by_subscriptions_feed_token(nil)
    assert_nil Family.find_by_subscriptions_feed_token("")

    token = family.enable_subscriptions_feed!

    assert family.subscriptions_feed_enabled?
    assert_operator token.length, :>=, 43
    assert_equal family, Family.find_by_subscriptions_feed_token(token)
    assert_equal token, family.enable_subscriptions_feed!, "enabling again keeps the link"
  end

  test "resetting the subscriptions feed gives a new token and the old one stops working" do
    family = families(:dylan_family)
    old_token = family.enable_subscriptions_feed!

    new_token = family.reset_subscriptions_feed!

    assert_not_equal old_token, new_token
    assert_nil Family.find_by_subscriptions_feed_token(old_token)
    assert_equal family, Family.find_by_subscriptions_feed_token(new_token)
  end

  test "disabling the subscriptions feed removes the token" do
    family = families(:dylan_family)
    token = family.enable_subscriptions_feed!

    family.disable_subscriptions_feed!

    assert_not family.reload.subscriptions_feed_enabled?
    assert_nil Family.find_by_subscriptions_feed_token(token)
  end

  test "rejects a time zone ActiveSupport does not know" do
    family = families(:dylan_family)
    family.timezone = "Invalid/Timezone"

    assert_not family.valid?
    assert family.errors.of_kind?(:timezone, :invalid)
  end

  test "accepts the zone identifier the preferences form submits, and a blank zone" do
    family = families(:dylan_family)

    family.timezone = "Europe/Kyiv"
    assert family.valid?

    family.timezone = nil
    assert family.valid?
  end

  test "an existing bad time zone does not block other saves" do
    family = families(:dylan_family)
    family.update_column(:timezone, "Invalid/Timezone")

    assert family.update(name: "Renamed family")
  end

  test "currency is saved as its upper-case ISO code" do
    family = families(:dylan_family)
    family.update!(currency: "uah")

    assert_equal "UAH", family.reload.currency
  end

  test "a stored lower-case currency is upper-cased on the next save" do
    family = families(:dylan_family)
    family.update_column(:currency, "uah")

    family.update!(name: "Renamed family")

    assert_equal "UAH", family.reload.currency
  end

  test "rejects a blank or unknown currency" do
    family = families(:dylan_family)
    original = family.currency

    [ "", nil, "XYZ" ].each do |value|
      assert_not family.update(currency: value)
      assert family.errors.of_kind?(:currency, :invalid)
    end
    assert_equal original, family.reload.currency
  end

  test "an existing unknown currency does not block other saves" do
    family = families(:dylan_family)
    family.update_column(:currency, "XYZ")

    assert family.update(name: "Renamed family")
  end

  test "resolved_time_zone gives the family zone" do
    family = families(:dylan_family)
    family.update!(timezone: "Europe/Kyiv")

    assert_equal "Europe/Kyiv", family.resolved_time_zone.tzinfo.identifier
  end

  test "resolved_time_zone gives UTC for a blank zone without logging" do
    family = families(:dylan_family)
    family.update_column(:timezone, nil)

    assert_no_difference "DebugLogEntry.count" do
      assert_equal "UTC", family.resolved_time_zone.name
    end
  end

  test "resolved_time_zone gives UTC for a bad zone and logs it once a day" do
    family = families(:dylan_family)
    family.update_column(:timezone, "Invalid/Timezone")
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    assert_difference -> { DebugLogEntry.where(category: "time_zone", level: "warn", family: family).count }, 1 do
      assert_equal "UTC", Family.find(family.id).resolved_time_zone.name
      assert_equal "UTC", Family.find(family.id).resolved_time_zone.name
    end

    travel 25.hours do
      assert_difference -> { DebugLogEntry.count }, 1 do
        Family.find(family.id).resolved_time_zone
      end
    end
  ensure
    Rails.cache = original_cache
  end

  # --- Exchange rate notes and cache key (w1-fx nearest-rate) ---

  test "build_cache_key changes when a new rate into the family currency is stored" do
    family = families(:empty)
    family.update_columns(currency: "UAH")

    before = family.build_cache_key("balance_sheet_account_rows")

    travel 1.second do
      ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 41)
    end

    assert_not_equal before, family.build_cache_key("balance_sheet_account_rows")
  end

  test "build_cache_key ignores rates into other currencies" do
    family = families(:empty)
    family.update_columns(currency: "UAH")

    before = family.build_cache_key("balance_sheet_account_rows")
    ExchangeRate.create!(from_currency: "USD", to_currency: "PLN", date: Date.current, rate: 4)

    assert_equal before, family.build_cache_key("balance_sheet_account_rows")
  end

  test "currencies_without_exchange_rate names currencies in use with no stored rate" do
    family = families(:empty)
    family.update_columns(currency: "UAH")
    family.accounts.create!(name: "USD cash", balance: 100, currency: "USD", accountable: Depository.new)
    family.accounts.create!(name: "EUR cash", balance: 100, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 100.days.ago.to_date, rate: 45)

    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", family: family).count }, 1 do
      assert_equal [ "USD" ], Family.find(family.id).currencies_without_exchange_rate
    end
  end

  test "stale_exchange_rate_dates names a held currency whose newest rate is old" do
    family = families(:empty)
    family.update_columns(currency: "UAH")
    family.accounts.create!(name: "EUR cash", balance: 100, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "UAH", date: 30.days.ago.to_date, rate: 45)

    assert_equal({ "EUR" => 30.days.ago.to_date }, Family.find(family.id).stale_exchange_rate_dates)
  end

  test "an old entry's currency can be missing but never stale; current holdings and subscriptions are held" do
    family = families(:empty)
    family.update_columns(currency: "UAH")
    account = family.accounts.create!(name: "UAH brokerage", balance: 0, currency: "UAH", accountable: Investment.new)
    account.entries.create!(name: "Old GBP purchase", date: 400.days.ago.to_date, amount: 10, currency: "GBP", entryable: Transaction.new)
    account.entries.create!(name: "Old PLN purchase", date: 400.days.ago.to_date, amount: 10, currency: "PLN", entryable: Transaction.new)
    security = Security.create!(ticker: "FXT#{SecureRandom.hex(3)}", name: "FX test")
    account.holdings.create!(security: security, date: 10.days.ago.to_date, qty: 1, price: 1, amount: 1, currency: "CHF")
    account.holdings.create!(security: security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "EUR")
    family.recurring_transactions.create!(name: "Stream", amount: 10, currency: "USD", expected_day_of_month: 1, last_occurrence_date: 1.month.ago.to_date, next_expected_date: 1.month.from_now.to_date, subscription_state: "subscription", status: "active")
    [ "GBP", "CHF", "EUR", "USD" ].each { |from| ExchangeRate.create!(from_currency: from, to_currency: "UAH", date: 30.days.ago.to_date, rate: 40) }

    reloaded = Family.find(family.id)

    assert_equal [ "PLN" ], reloaded.currencies_without_exchange_rate
    # GBP only appears on an old entry, CHF only on an earlier holding date
    assert_equal({ "EUR" => 30.days.ago.to_date, "USD" => 30.days.ago.to_date }, reloaded.stale_exchange_rate_dates)
  end

  # --- Enabled currencies (w1-ds money field) ---

  test "nil enabled_currencies offers every currency" do
    family = families(:dylan_family)
    family.update!(enabled_currencies: nil)

    assert_not family.custom_enabled_currencies?
    assert_equal Money::Currency.as_options.map(&:iso_code), family.enabled_currency_codes
  end

  test "enabled_currencies always keeps the base currency and drops unknown codes" do
    family = families(:dylan_family)
    family.update!(currency: "UAH", enabled_currencies: [ "usd", "EUR", "NOPE", "" ])

    assert_equal [ "UAH", "USD", "EUR" ], family.reload.enabled_currencies
    assert_equal [ "UAH", "USD", "EUR" ], family.enabled_currency_codes
  end

  test "a blank list or every currency ticked is stored as nil" do
    family = families(:dylan_family)

    family.update!(enabled_currencies: [])
    assert_nil family.reload.enabled_currencies

    family.update!(enabled_currencies: Money::Currency.as_options.map(&:iso_code))
    assert_nil family.reload.enabled_currencies
  end

  test "a record's own currency is offered even when it was turned off" do
    family = families(:dylan_family)
    family.update!(currency: "UAH", enabled_currencies: [ "UAH", "USD" ])

    assert_equal [ "UAH", "USD", "GBP" ], family.enabled_currency_codes(extra: "GBP")
    assert_equal [ "UAH", "USD" ], family.enabled_currency_codes(extra: "USD")
    assert_equal [ "USD" ], family.secondary_enabled_currency_objects.map(&:iso_code)
  end

  test "earliest_activity_date ignores valuations and takes the earliest transaction or trade" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "UAH", accountable: Depository.new)

    account.entries.create!(date: Date.new(2000, 1, 15), name: "Old valuation",
                            amount: 5000, currency: "UAH", entryable: Valuation.new)
    transaction_date = Date.new(2025, 3, 10)
    account.entries.create!(date: transaction_date, name: "Groceries",
                            amount: -50, currency: "UAH", entryable: Transaction.new)

    assert_equal transaction_date, family.earliest_activity_date
    # oldest_entry_date still counts every entry type
    assert_equal Date.new(2000, 1, 15), family.oldest_entry_date

    # An earlier Trade wins, so dropping Trade from the filter is caught
    trade_date = Date.new(2020, 6, 15)
    account.entries.create!(date: trade_date, name: "Investment purchase",
                            amount: 100, currency: "UAH",
                            entryable: Trade.new(security: securities(:aapl), qty: 1, price: 100, currency: "UAH"))

    assert_equal trade_date, family.earliest_activity_date
  end

  test "earliest_activity_date is nil without transactions or trades" do
    family = families(:empty)
    assert_nil family.earliest_activity_date

    account = family.accounts.create!(name: "House", balance: 0, currency: "UAH", accountable: Depository.new)
    account.entries.create!(date: Date.new(2000, 1, 15), name: "Old valuation",
                            amount: 5000, currency: "UAH", entryable: Valuation.new)

    assert_nil family.earliest_activity_date
  end
end
