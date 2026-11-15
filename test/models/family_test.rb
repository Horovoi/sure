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
end
