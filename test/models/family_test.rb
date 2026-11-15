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
end
