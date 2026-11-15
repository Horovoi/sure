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
end
