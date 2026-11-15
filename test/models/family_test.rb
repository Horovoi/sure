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
