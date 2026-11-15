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
end
