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
      subscription_state: "subscription",
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
      subscription_state: "subscription",
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

    # The day drawer is built from this value
    data = JSON.parse(css_select("[data-controller='subscription-calendar']").first["data-subscription-calendar-data-value"])
    assert_equal @family.currency, data["family_currency"]
    assert_kind_of Hash, data["dates"]
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

  test "create marks a hand-made subscription as a subscription" do
    post subscriptions_url, params: {
      recurring_transaction: {
        name: "Gym", amount: 30, currency: "USD", billing_cycle: "monthly", expected_day_of_month: 3
      }
    }

    created = @family.recurring_transactions.find_by!(name: "Gym")
    assert created.subscription?
    assert created.user_managed?
  end

  test "skip_occurrence advances one period from the current expected date" do
    @subscription.update!(next_expected_date: 2.days.ago.to_date, last_occurrence_date: 2.months.ago.to_date)

    post skip_occurrence_subscription_url(@subscription)

    assert_equal 2.days.ago.to_date.next_month.change(day: 5), @subscription.reload.next_expected_date
  end

  test "toggle_status pause is not undone by the identifier" do
    post toggle_status_subscription_url(@subscription)

    @subscription.reload
    assert @subscription.inactive?
    assert_equal "user", @subscription.inactive_reason
  end

  test "record_transaction refuses a subscription that is not due" do
    @subscription.update!(default_account: accounts(:depository), next_expected_date: 5.days.from_now.to_date)

    assert_no_difference "Entry.count" do
      post record_transaction_subscription_url(@subscription)
    end

    assert_redirected_to subscriptions_path
    assert_equal I18n.t("subscriptions.record_transaction.not_due"), flash[:alert]
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
      subscription_state: "subscription"
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
      subscription_state: "suggested"
    )
    suggestion2 = @family.recurring_transactions.create!(
      name: "Netflix",
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 20,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "suggested"
    )

    assert_equal 2, @family.recurring_transactions.suggested.count

    post dismiss_all_suggestions_subscriptions_url

    assert_redirected_to subscriptions_path
    assert_equal 0, @family.recurring_transactions.suggested.count
    assert suggestion1.reload.dismissed_at.present?
    assert suggestion2.reload.dismissed_at.present?
  end

  test "suggestions page shows both suggested and dismissed suggestions" do
    # Create suggested subscription
    @family.recurring_transactions.create!(
      name: "Spotify",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "suggested"
    )

    # Create dismissed subscription
    @family.recurring_transactions.create!(
      name: "Hulu",
      amount: 12.99,
      currency: "USD",
      expected_day_of_month: 20,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "dismissed",
      dismissed_at: 1.day.ago
    )

    get suggestions_subscriptions_url
    assert_response :success
    assert_select "div#suggestions_list"
    assert_select "div#dismissed_container"
  end

  test "restore_suggestion moves dismissed suggestion back to suggested" do
    dismissed = @family.recurring_transactions.create!(
      name: "Spotify",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "dismissed",
      dismissed_at: 1.day.ago
    )

    assert_equal 1, @family.recurring_transactions.dismissed.count
    assert_equal 0, @family.recurring_transactions.suggested.count

    post restore_suggestion_subscription_url(dismissed)

    assert_redirected_to suggestions_subscriptions_path
    dismissed.reload
    assert_equal "suggested", dismissed.suggestion_status
    assert_nil dismissed.dismissed_at
    assert_equal 0, @family.recurring_transactions.dismissed.count
    assert_equal 1, @family.recurring_transactions.suggested.count
  end

  test "restore_suggestion responds with turbo_stream" do
    dismissed = @family.recurring_transactions.create!(
      name: "Spotify",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "dismissed",
      dismissed_at: 1.day.ago
    )

    post restore_suggestion_subscription_url(dismissed), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "cannot restore suggestion from other family" do
    other_family = families(:empty)
    other_dismissed = other_family.recurring_transactions.create!(
      name: "Other Family Dismissed",
      amount: 10.00,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "dismissed",
      dismissed_at: 1.day.ago
    )

    post restore_suggestion_subscription_url(other_dismissed)
    assert_response :not_found
  end

  test "detect redirects to suggestions when only dismissed suggestions exist" do
    # Create a dismissed suggestion
    @family.recurring_transactions.create!(
      name: "Dismissed Service",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      subscription_state: "dismissed",
      dismissed_at: 1.day.ago
    )

    assert_equal 0, @family.recurring_transactions.suggested.count
    assert_equal 1, @family.recurring_transactions.dismissed.count

    post detect_subscriptions_url

    assert_redirected_to suggestions_subscriptions_path
    assert_match(/previously dismissed/, flash[:notice])
  end
end
