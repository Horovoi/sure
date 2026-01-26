require "test_helper"

class RecurringTransaction::SubscriptionDetectorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  def setup
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
  end

  test "likely_subscription? returns true for known service merchant" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active"
    )

    assert RecurringTransaction::SubscriptionDetector.likely_subscription?(recurring)
  end

  test "likely_subscription? returns true for name containing known service" do
    recurring = @family.recurring_transactions.create!(
      name: "Spotify Premium",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active"
    )

    assert RecurringTransaction::SubscriptionDetector.likely_subscription?(recurring)
  end

  test "likely_subscription? returns false for non-subscription merchant" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:starbucks),
      amount: 5.00,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active"
    )

    assert_not RecurringTransaction::SubscriptionDetector.likely_subscription?(recurring)
  end

  test "detect_billing_cycle returns monthly for ~30 day gaps" do
    dates = [
      Date.new(2025, 1, 15),
      Date.new(2025, 2, 15),
      Date.new(2025, 3, 15)
    ]

    assert_equal :monthly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates)
  end

  test "detect_billing_cycle returns yearly for ~365 day gaps" do
    dates = [
      Date.new(2023, 1, 15),
      Date.new(2024, 1, 15),
      Date.new(2025, 1, 15)
    ]

    assert_equal :yearly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates)
  end

  test "detect_billing_cycle returns monthly for single recent transaction" do
    # Single transaction from 30 days ago → monthly (not enough time elapsed)
    dates = [ 30.days.ago.to_date ]

    assert_equal :monthly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates)
  end

  test "detect_billing_cycle returns yearly for single transaction 90+ days old" do
    # Single transaction from 100 days ago → yearly (enough time elapsed without another charge)
    dates = [ 100.days.ago.to_date ]

    assert_equal :yearly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates)
  end

  test "detect_billing_cycle returns yearly for single transaction 45-89 days with high price" do
    # Single transaction from 50 days ago with $60 amount → yearly
    dates = [ 50.days.ago.to_date ]

    assert_equal :yearly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates, amount: 60)
  end

  test "detect_billing_cycle returns monthly for single transaction 45-89 days with low price" do
    # Single transaction from 50 days ago with $20 amount → monthly (price too low)
    dates = [ 50.days.ago.to_date ]

    assert_equal :monthly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates, amount: 20)
  end

  test "detect_billing_cycle returns monthly for single transaction under 45 days even with high price" do
    # Single transaction from 30 days ago with $100 amount → still monthly (not enough time)
    dates = [ 30.days.ago.to_date ]

    assert_equal :monthly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates, amount: 100)
  end

  test "detect_for_family marks matching recurring transactions as suggestions" do
    # Create a recurring transaction with Netflix merchant
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    recurring.reload
    assert_equal "suggested", recurring.suggestion_status
  end

  test "detect_for_family does not mark non-matching transactions as suggestions" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:starbucks),
      amount: 5.00,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    recurring.reload
    assert_nil recurring.suggestion_status
  end

  test "detect_for_family skips when subscription already exists with same merchant" do
    # Create existing subscription for Netflix
    @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: true
    )

    # Create non-subscription with same merchant but different amount
    duplicate = @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 16.50,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    duplicate.reload
    assert_nil duplicate.suggestion_status, "Should not suggest duplicate of existing subscription"
  end

  test "detect_for_family skips when subscription exists with similar name variation" do
    # Create existing subscription with name "iCloud+"
    @family.recurring_transactions.create!(
      name: "iCloud+",
      amount: 2.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: true
    )

    # Create non-subscription with similar name "iCloud" (without plus)
    duplicate = @family.recurring_transactions.create!(
      name: "iCloud",
      amount: 3.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    duplicate.reload
    assert_nil duplicate.suggestion_status, "Should not suggest duplicate when similar name subscription exists"
  end

  test "detect_for_family skips when subscription exists in different currency" do
    # Create existing subscription in USD
    @family.recurring_transactions.create!(
      name: "iCloud",
      amount: 3.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: true
    )

    # Create non-subscription with same name but different currency (e.g., local currency)
    duplicate = @family.recurring_transactions.create!(
      name: "iCloud",
      amount: 127.79,
      currency: "UAH",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    duplicate.reload
    assert_nil duplicate.suggestion_status, "Should not suggest duplicate when subscription exists in different currency"
  end

  # Dismissed suggestions behavior tests

  test "detect_for_family does not reset dismissed suggestions" do
    # Create a dismissed recurring transaction
    dismissed = @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false,
      suggestion_status: "dismissed",
      dismissed_at: 1.day.ago
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    dismissed.reload
    assert_equal "dismissed", dismissed.suggestion_status, "Dismissed suggestions should stay dismissed"
    assert_not_nil dismissed.dismissed_at, "dismissed_at should not be cleared"
  end

  test "detect_for_family does not re-suggest dismissed suggestions" do
    # Create a dismissed recurring transaction
    @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: false,
      suggestion_status: "dismissed",
      dismissed_at: 1.day.ago
    )

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    # Should still have exactly one recurring transaction, and it should still be dismissed
    assert_equal 1, @family.recurring_transactions.count
    assert_equal 1, @family.recurring_transactions.dismissed.count
    assert_equal 0, @family.recurring_transactions.suggested.count
  end
end
