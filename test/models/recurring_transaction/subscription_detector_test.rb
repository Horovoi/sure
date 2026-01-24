require "test_helper"

class RecurringTransaction::SubscriptionDetectorTest < ActiveSupport::TestCase
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

  test "detect_billing_cycle returns monthly for single date" do
    dates = [ Date.new(2025, 1, 15) ]

    assert_equal :monthly, RecurringTransaction::SubscriptionDetector.detect_billing_cycle(dates)
  end

  test "detect_for_family marks matching recurring transactions as subscriptions" do
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
    assert recurring.is_subscription?
  end

  test "detect_for_family does not mark non-matching transactions" do
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
    assert_not recurring.is_subscription?
  end
end
