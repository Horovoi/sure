require "test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all

    @subscription = @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: true,
      billing_cycle: "monthly"
    )
  end

  test "index shows subscriptions list" do
    get subscriptions_url
    assert_response :success
    assert_select "h1", /Subscriptions/i
  end

  test "index filters by status" do
    # Create inactive subscription
    inactive = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 10,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "inactive",
      is_subscription: true,
      billing_cycle: "monthly"
    )

    get subscriptions_url(status: "active")
    assert_response :success

    get subscriptions_url(status: "inactive")
    assert_response :success
  end

  test "index filters by billing cycle" do
    get subscriptions_url(billing_cycle: "monthly")
    assert_response :success

    get subscriptions_url(billing_cycle: "yearly")
    assert_response :success
  end

  test "calendar shows calendar view" do
    get calendar_subscriptions_url
    assert_response :success
  end

  test "calendar accepts month parameter" do
    get calendar_subscriptions_url(month: "2025-06-01")
    assert_response :success
  end

  test "new shows subscription form" do
    get new_subscription_url
    assert_response :success
  end

  test "create creates a new subscription" do
    assert_difference "@family.recurring_transactions.subscriptions.count", 1 do
      post subscriptions_url, params: {
        recurring_transaction: {
          name: "New Subscription",
          amount: 19.99,
          currency: "USD",
          billing_cycle: "monthly",
          expected_day_of_month: 15
        }
      }
    end

    assert_redirected_to subscriptions_path
    subscription = @family.recurring_transactions.subscriptions.order(:created_at).last
    assert subscription.is_subscription?
    assert_equal "New Subscription", subscription.name
    assert_equal 19.99, subscription.amount
    assert subscription.billing_cycle_monthly?
  end

  test "create fails with invalid params" do
    assert_no_difference "@family.recurring_transactions.count" do
      post subscriptions_url, params: {
        recurring_transaction: {
          name: "",
          amount: nil
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "edit shows subscription form" do
    get edit_subscription_url(@subscription)
    assert_response :success
  end

  test "update updates subscription" do
    patch subscription_url(@subscription), params: {
      recurring_transaction: {
        name: "Updated Name",
        amount: 25.99,
        billing_cycle: "yearly",
        expected_month: 6
      }
    }

    assert_redirected_to subscriptions_path
    @subscription.reload
    assert_equal 25.99, @subscription.amount
    assert @subscription.billing_cycle_yearly?
  end

  test "destroy removes subscription" do
    assert_difference "@family.recurring_transactions.count", -1 do
      delete subscription_url(@subscription)
    end

    assert_redirected_to subscriptions_path
  end

  test "toggle_status activates inactive subscription" do
    @subscription.update!(status: "inactive")

    post toggle_status_subscription_url(@subscription)

    assert_redirected_to subscriptions_path
    assert @subscription.reload.active?
  end

  test "toggle_status deactivates active subscription" do
    post toggle_status_subscription_url(@subscription)

    assert_redirected_to subscriptions_path
    assert @subscription.reload.inactive?
  end

  test "cannot access other family subscriptions" do
    other_family = families(:empty)
    other_subscription = other_family.recurring_transactions.create!(
      name: "Other Family Sub",
      amount: 10.00,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      is_subscription: true
    )

    get edit_subscription_url(other_subscription)
    assert_response :not_found
  end

  test "dismiss_all_suggestions dismisses all suggested subscriptions" do
    # Create suggested subscriptions
    suggestion1 = @family.recurring_transactions.create!(
      name: "Spotify",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      suggestion_status: "suggested"
    )
    suggestion2 = @family.recurring_transactions.create!(
      name: "Netflix",
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 20,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      suggestion_status: "suggested"
    )

    assert_equal 2, @family.recurring_transactions.suggested.count

    post dismiss_all_suggestions_subscriptions_url

    assert_redirected_to subscriptions_path
    assert_equal 0, @family.recurring_transactions.suggested.count
    assert suggestion1.reload.dismissed_at.present?
    assert suggestion2.reload.dismissed_at.present?
  end
end
