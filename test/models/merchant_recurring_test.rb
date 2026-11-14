require "test_helper"

# Merging, deleting, converting and unlinking merchants must keep the
# recurring rows and subscriptions attached to them.
class MerchantRecurringTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    @netflix = merchants(:netflix)
    @amazon = merchants(:amazon)
  end

  test "merging merchants moves subscriptions to the target instead of deleting them" do
    subscription = create_recurring(merchant: @netflix, subscription_state: "subscription", notes: "keep me")
    entry = create_transaction(merchant: @netflix, name: "Netflix")
    entry.transaction.update!(recurring_transaction: subscription)

    Merchant::Merger.new(family: @family, target_merchant: @amazon, source_merchants: [ @netflix ]).merge!

    refute Merchant.exists?(@netflix.id)
    subscription.reload
    assert_equal @amazon.id, subscription.merchant_id
    assert_equal "keep me", subscription.notes
    assert_equal subscription.id, entry.transaction.reload.recurring_transaction_id
  end

  test "merging into a merchant with the same recurring row keeps the subscription" do
    pattern = create_recurring(merchant: @amazon, subscription_state: "pattern")
    subscription = create_recurring(merchant: @netflix, subscription_state: "subscription")
    entry = create_transaction(merchant: @amazon, name: "Amazon")
    entry.transaction.update!(recurring_transaction: pattern)

    Merchant::Merger.new(family: @family, target_merchant: @amazon, source_merchants: [ @netflix ]).merge!

    refute RecurringTransaction.exists?(pattern.id)
    assert_equal @amazon.id, subscription.reload.merchant_id
    assert_equal subscription.id, entry.transaction.reload.recurring_transaction_id
  end

  test "merging into a merchant whose recurring row has a name does not collide" do
    named_subscription = create_recurring(merchant: @amazon, subscription_state: "subscription", name: "Prime")
    pattern = create_recurring(merchant: @netflix, subscription_state: "pattern")

    Merchant::Merger.new(family: @family, target_merchant: @amazon, source_merchants: [ @netflix ]).merge!

    refute RecurringTransaction.exists?(pattern.id)
    assert_equal @amazon.id, named_subscription.reload.merchant_id
  end

  test "deleting a merchant turns its subscriptions into name-based ones" do
    subscription = create_recurring(merchant: @netflix, subscription_state: "subscription")

    @netflix.destroy!

    subscription.reload
    assert_nil subscription.merchant_id
    assert_equal "Netflix", subscription.name
    assert subscription.subscription?
  end

  test "converting a provider merchant moves the family's recurring rows" do
    provider = ProviderMerchant.create!(name: "Spotify AI", source: "ai")
    create_transaction(merchant: provider, name: "Spotify")
    recurring = create_recurring(merchant: provider)

    family_merchant = provider.convert_to_family_merchant_for(@family)

    assert_equal family_merchant.id, recurring.reload.merchant_id
  end

  test "unlinking a provider merchant keeps the family's recurring rows as name-based" do
    provider = ProviderMerchant.create!(name: "Spotify AI", source: "ai")
    create_transaction(merchant: provider, name: "Spotify")
    recurring = create_recurring(merchant: provider, subscription_state: "subscription")

    provider.unlink_from_family(@family)

    recurring.reload
    assert_nil recurring.merchant_id
    assert_equal "Spotify AI", recurring.name
    assert FamilyMerchantAssociation.exists?(family: @family, merchant: provider)
  end

  test "family merchant keeps the colour the user chose" do
    merchant = @family.merchants.create!(name: "Coloured", color: "#123456")
    merchant.update!(name: "Renamed")

    assert_equal "#123456", merchant.reload.color
  end

  private
    def create_recurring(merchant:, subscription_state: "pattern", **attrs)
      @family.recurring_transactions.create!({
        merchant: merchant,
        amount: 15.99,
        currency: "USD",
        expected_day_of_month: 5,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 5.days.from_now.to_date,
        status: "active",
        subscription_state: subscription_state
      }.merge(attrs))
    end
end
