require "test_helper"

# create_subscription, update_subscription, review_subscription_suggestion, skip_subscription_occurrence and
# record_subscription_charge. Every one is a write tool the chat and /mcp both get, with no approval prompt.
class Assistant::Function::SubscriptionWriteToolsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
  end

  test "every subscription write tool is a write tool with an audit record type" do
    [
      Assistant::Function::CreateSubscription, Assistant::Function::UpdateSubscription,
      Assistant::Function::ReviewSubscriptionSuggestion, Assistant::Function::SkipSubscriptionOccurrence,
      Assistant::Function::RecordSubscriptionCharge
    ].each do |function_class|
      function = function_class.new(@user)
      assert_equal :write, function.scope_tag, function.name
      assert function.record_type.present?, function.name
      assert_equal false, function.mcp_annotations[:destructive_hint], function.name
      assert_no_match(/confirm/i, function.description, "#{function.name} must describe the effect, not ask for a confirmation")
    end
  end

  # --- create_subscription --------------------------------------------------------------------------------

  test "create_subscription adds a monthly subscription paid from an account" do
    fn = Assistant::Function::CreateSubscription.new(@user)

    result = fn.call("name" => "Gym", "amount" => 1200, "currency" => "UAH", "billing_cycle" => "monthly",
      "expected_day_of_month" => 10, "default_account_id" => @account.id)

    assert_equal true, result[:created]
    row = @family.recurring_transactions.find(result[:id])
    assert row.subscription?
    assert row.active?
    assert_equal "Gym", row.name
    assert_equal 1200, row.amount
    assert_equal "UAH", row.currency
    assert_equal @account, row.default_account
    assert_equal row.first_expected_date, row.next_expected_date
    assert_equal "subscription", result.dig(:subscription, :kind)
  end

  test "create_subscription is idempotent by identity" do
    fn = Assistant::Function::CreateSubscription.new(@user)
    arguments = { "merchant_id" => merchants(:netflix).id, "amount" => 15.99, "currency" => "USD", "expected_day_of_month" => 5 }

    first = fn.call(arguments)
    assert_no_difference -> { @family.recurring_transactions.count } do
      second = fn.call(arguments.merge("amount" => 16.49)) # within 15%: the same subscription
      assert_equal false, second[:created]
      assert_equal first[:id], second[:id]
    end
  end

  test "create_subscription turns a detected suggestion with the identity into the subscription" do
    suggestion = @family.recurring_transactions.create!(
      name: "Spotify", amount: 199, currency: "UAH", expected_day_of_month: 3,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: 3.days.from_now.to_date, subscription_state: "suggested"
    )

    result = Assistant::Function::CreateSubscription.new(@user).call("name" => "Spotify", "amount" => 199, "currency" => "UAH")

    assert_equal suggestion.id, result[:id]
    assert_equal false, result[:created]
    assert_equal true, result[:converted]
    assert suggestion.reload.subscription?
  end

  test "create_subscription makes one from a transaction through mark_from_transaction!" do
    transaction = transactions(:one)

    result = Assistant::Function::CreateSubscription.new(@user).call("transaction_id" => transaction.id)

    assert_equal true, result[:created]
    row = @family.recurring_transactions.find(result[:id])
    assert row.subscription?
    assert_equal merchants(:amazon), row.merchant
    assert_equal categories(:subscriptions), row.category

    again = Assistant::Function::CreateSubscription.new(@user).call("transaction_id" => transaction.id)
    assert_equal row.id, again[:id]
    assert_equal false, again[:created]
  end

  test "create_subscription refuses bad arguments as error data" do
    fn = Assistant::Function::CreateSubscription.new(@user)

    assert_equal "missing_name", fn.call("amount" => 10)[:error]
    assert_equal "missing_amount", fn.call("name" => "X")[:error]
    assert_equal "invalid_amount", fn.call("name" => "X", "amount" => -5)[:error]
    assert_equal "invalid_currency", fn.call("name" => "X", "amount" => 5, "currency" => "ZZZ")[:error]
    assert_equal "missing_expected_month", fn.call("name" => "X", "amount" => 5, "billing_cycle" => "yearly")[:error]
    assert_equal "invalid_account", fn.call("name" => "X", "amount" => 5, "default_account_id" => SecureRandom.uuid)[:error]
    assert_equal "transaction_not_found", fn.call("transaction_id" => SecureRandom.uuid)[:error]
  end

  # --- update_subscription --------------------------------------------------------------------------------

  test "update_subscription changes fields and records the state before" do
    row = subscription(amount: 15.99)
    fn = Assistant::Function::UpdateSubscription.new(@user)

    before = fn.audit_before("id" => row.id)
    result = fn.call("id" => row.id, "amount" => 17.99, "notes" => "Price went up")

    assert result[:updated]
    assert_equal row.id, result[:id]
    assert_in_delta 15.99, before[:amount], 0.001
    assert_equal 17.99, row.reload.amount
    assert_equal "Price went up", row.notes
    assert fn.idempotent?
  end

  test "update_subscription moves the next date when the billing day changes" do
    row = subscription(day: 5)

    Assistant::Function::UpdateSubscription.new(@user).call("id" => row.id, "expected_day_of_month" => 20)

    row.reload
    assert_equal 20, row.expected_day_of_month
    assert_equal row.first_expected_date, row.next_expected_date
  end

  test "update_subscription pauses through mark_inactive! and resumes through mark_active!" do
    row = subscription(next_date: 10.days.ago)
    fn = Assistant::Function::UpdateSubscription.new(@user)

    fn.call("id" => row.id, "status" => "paused")
    row.reload
    assert row.inactive?
    assert_equal "user", row.inactive_reason

    fn.call("id" => row.id, "status" => "active")
    row.reload
    assert row.active?
    assert_nil row.inactive_reason
    assert row.next_expected_date > Date.current, "a resumed row starts from its next future date"
  end

  test "update_subscription refuses a detected suggestion, an unknown id and no changes" do
    suggestion = subscription(state: "suggested")
    fn = Assistant::Function::UpdateSubscription.new(@user)

    assert_equal "not_editable", fn.call("id" => suggestion.id, "amount" => 5)[:error]
    assert_equal "not_found", fn.call("id" => SecureRandom.uuid, "amount" => 5)[:error]
    assert_equal "no_changes", fn.call("id" => subscription(name: "Other").id)[:error]
    assert_equal "invalid_status", fn.call("id" => subscription(name: "Third").id, "status" => "stopped")[:error]
  end

  # --- review_subscription_suggestion ---------------------------------------------------------------------

  test "approve turns a suggestion into a subscription in the Subscriptions category" do
    suggestion = subscription(state: "suggested", next_date: 3.days.ago)
    suggestion.update!(inferred_account: @account)
    fn = Assistant::Function::ReviewSubscriptionSuggestion.new(@user)

    result = fn.call("id" => suggestion.id, "decision" => "approve")

    suggestion.reload
    assert suggestion.subscription?
    assert_equal categories(:subscriptions), suggestion.category
    assert_equal @account, suggestion.default_account
    assert suggestion.next_expected_date > Date.current
    assert_equal "subscription", result.dig(:subscription, :kind)
  end

  test "approve with use_base_currency keeps the detected base amount" do
    suggestion = subscription(state: "suggested", amount: 10, currency: "USD")
    suggestion.update!(detected_base_currency: "UAH", detected_base_amount: 415)

    Assistant::Function::ReviewSubscriptionSuggestion.new(@user).call("id" => suggestion.id, "decision" => "approve", "use_base_currency" => true)

    suggestion.reload
    assert_equal "UAH", suggestion.currency
    assert_equal 415, suggestion.amount
  end

  test "dismiss and restore move a suggestion through its AASM events" do
    suggestion = subscription(state: "suggested")
    fn = Assistant::Function::ReviewSubscriptionSuggestion.new(@user)

    fn.call("id" => suggestion.id, "decision" => "dismiss")
    assert suggestion.reload.dismissed?
    assert suggestion.dismissed_at.present?

    fn.call("id" => suggestion.id, "decision" => "restore")
    assert suggestion.reload.suggested?
    assert_nil suggestion.dismissed_at
  end

  test "an invalid transition returns error data and changes nothing" do
    row = subscription
    fn = Assistant::Function::ReviewSubscriptionSuggestion.new(@user)

    result = fn.call("id" => row.id, "decision" => "dismiss")

    assert_equal "invalid_transition", result[:error]
    assert_equal "subscription", result[:kind]
    assert row.reload.subscription?
    assert_equal "invalid_transition", fn.call("id" => subscription(name: "S", state: "suggested").id, "decision" => "restore")[:error]
    assert_equal "invalid_decision", fn.call("id" => row.id, "decision" => "delete")[:error]
  end

  # --- skip_subscription_occurrence -----------------------------------------------------------------------

  test "skip moves the next date one period on without a charge" do
    row = subscription(day: 5, next_date: Date.current.change(day: 5) + 1.month)
    next_date = row.next_expected_date

    assert_no_difference -> { Entry.count } do
      result = Assistant::Function::SkipSubscriptionOccurrence.new(@user).call("id" => row.id)
      assert_equal next_date.iso8601, result[:skipped_date]
    end

    assert_equal next_date.next_month.change(day: 5), row.reload.next_expected_date
  end

  test "skip refuses a row that is not a subscription" do
    suggestion = subscription(state: "suggested")

    assert_equal "not_found", Assistant::Function::SkipSubscriptionOccurrence.new(@user).call("id" => suggestion.id)[:error]
  end

  # --- record_subscription_charge -------------------------------------------------------------------------

  test "record books the due charge once and names the entry for the audit" do
    row = subscription(next_date: Date.current, default_account: @account)
    fn = Assistant::Function::RecordSubscriptionCharge.new(@user)
    Account.any_instance.stubs(:sync_later)

    result = nil
    assert_difference -> { @account.entries.count }, 1 do
      result = fn.call("id" => row.id)
      second = fn.call("id" => row.id)
      assert_equal "not_due", second[:error]
    end

    assert_equal row.id, result[:subscription_id]
    entry = Entry.find(result[:entry_id])
    assert_equal "subscription", entry.source
    assert_equal row, entry.transaction.recurring_transaction
    assert_equal [ entry.id ], fn.audit_refs(result)
    assert_equal "Entry", fn.record_type
    assert row.reload.next_expected_date > Date.current
  end

  test "record refuses a subscription that is not due or has no account" do
    fn = Assistant::Function::RecordSubscriptionCharge.new(@user)

    assert_equal "not_due", fn.call("id" => subscription(next_date: 5.days.from_now, default_account: @account).id)[:error]
    assert_equal "no_account", fn.call("id" => subscription(name: "No account", next_date: Date.current).id)[:error]
  end

  test "record refuses a charge whose currency has no rate into the account currency" do
    row = subscription(name: "Swiss", amount: 10, currency: "CHF", next_date: Date.current, default_account: @account)

    result = Assistant::Function::RecordSubscriptionCharge.new(@user).call("id" => row.id)

    assert_equal "no_exchange_rate", result[:error]
    assert_equal row.id, result[:subscription_id]
  end

  test "there is no subscription delete tool" do
    names = Assistant.function_classes.map(&:name)

    assert_not_includes names, "delete_subscription"
  end

  private
    def subscription(name: "Netflix", amount: 15.99, currency: "USD", day: nil, next_date: 5.days.from_now, state: "subscription", default_account: nil)
      next_date = next_date.to_date
      @family.recurring_transactions.create!(
        name: name, amount: amount, currency: currency,
        expected_day_of_month: day || next_date.day,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: next_date,
        status: "active", subscription_state: state, billing_cycle: "monthly", default_account: default_account
      )
    end
end
