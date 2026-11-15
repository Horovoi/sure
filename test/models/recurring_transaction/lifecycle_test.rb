require "test_helper"

# Regression tests for the recurring transaction lifecycle: stable identity,
# suggestion state, stale/resume, overdue dates and generation.
class RecurringTransaction::LifecycleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
    @merchant = merchants(:netflix)
  end

  test "drifting average updates the existing row instead of creating a duplicate" do
    create_monthly_charges(amounts: [ 15.99, 15.99, 15.99 ])
    identify
    recurring = recurring_rows.sole
    assert_equal 15.99, recurring.amount.to_f

    # A new charge at a slightly different price moves the average.
    create_charge(date: Date.current, amount: 16.49)
    identify

    assert_equal 1, recurring_rows.count
    assert_equal recurring.id, recurring_rows.sole.id
    assert_not_equal 15.99, recurring.reload.amount.to_f
  end

  test "a dismissed suggestion stays dismissed when its average drifts" do
    create_monthly_charges(amounts: [ 15.99, 15.99, 15.99 ])
    identify
    suggestion = recurring_rows.sole
    assert suggestion.suggested?
    suggestion.dismiss_suggestion!

    create_charge(date: Date.current, amount: 16.49)
    identify

    assert_equal [ "dismissed" ], recurring_rows.pluck(:subscription_state)
    assert_equal 0, recurring_rows.suggested.count
  end

  test "a dismissal also blocks a new pattern for the same merchant" do
    dismissed = create_recurring(subscription_state: "dismissed", amount: 99)
    pattern = create_recurring(subscription_state: "pattern", amount: 15.99)

    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    assert dismissed.reload.dismissed?
    assert pattern.reload.pattern?
  end

  test "state events write the legacy mirror columns" do
    recurring = create_recurring(subscription_state: "pattern")
    recurring.suggest!
    assert_equal [ false, "suggested" ], [ recurring.reload.read_attribute(:is_subscription), recurring.suggestion_status ]

    recurring.dismiss_suggestion!
    assert_equal "dismissed", recurring.reload.suggestion_status
    assert recurring.dismissed_at.present?

    recurring.restore_suggestion!
    assert recurring.reload.suggested?
    assert_nil recurring.dismissed_at

    recurring.approve_suggestion!
    recurring.reload
    assert recurring.subscription?
    assert_equal true, recurring.read_attribute(:is_subscription)
    assert_nil recurring.suggestion_status
  end

  test "a stale pattern is reactivated when it resumes, a paused one is not" do
    stale = create_recurring(subscription_state: "pattern", amount: 15.99, status: "inactive", inactive_reason: "stale")
    other_merchant = merchants(:amazon)
    paused = create_recurring(subscription_state: "pattern", amount: 9.99, merchant: other_merchant, status: "inactive", inactive_reason: "user")

    create_monthly_charges(amounts: [ 15.99, 15.99, 15.99 ])
    create_monthly_charges(amounts: [ 9.99, 9.99, 9.99 ], merchant: other_merchant, name: "Amazon")
    identify

    assert stale.reload.active?
    assert_nil stale.inactive_reason
    assert paused.reload.inactive?
  end

  test "identifier keeps user settings on an approved subscription" do
    subscription = create_recurring(subscription_state: "subscription", amount: 15.99, expected_day_of_month: 20,
                                    occurrence_count: 1, last_occurrence_date: 3.months.ago.to_date,
                                    next_expected_date: 10.days.from_now.to_date)

    create_monthly_charges(amounts: [ 16.20, 16.20, 16.20 ])
    identify

    subscription.reload
    assert_equal 1, recurring_rows.count
    assert_equal 15.99, subscription.amount.to_f
    assert_equal 20, subscription.expected_day_of_month
    assert_equal 1, subscription.occurrence_count
    assert_equal Date.current.beginning_of_month + 5.days, subscription.last_occurrence_date
  end

  test "saving an overdue subscription keeps its overdue date" do
    subscription = create_recurring(subscription_state: "subscription", next_expected_date: 3.days.ago.to_date)

    subscription.update!(notes: "edited")

    assert_equal 3.days.ago.to_date, subscription.reload.next_expected_date
    assert subscription.overdue?
  end

  test "approving a suggestion or resuming a subscription starts from the next future date" do
    suggestion = create_recurring(subscription_state: "suggested", next_expected_date: 3.days.ago.to_date)
    suggestion.approve_suggestion!
    assert suggestion.reload.next_expected_date > Date.current

    paused = create_recurring(subscription_state: "subscription", merchant: merchants(:amazon), status: "inactive",
                              next_expected_date: 2.months.ago.to_date)
    paused.mark_active!
    assert paused.reload.next_expected_date > Date.current
  end

  test "generate_transaction! creates one entry per period and never a future one" do
    subscription = create_recurring(subscription_state: "subscription", default_account: @account,
                                    next_expected_date: Date.current)

    assert_difference "Entry.count", 1 do
      assert subscription.generate_transaction!(for_date: Date.current)
      assert_nil subscription.reload.generate_transaction!(for_date: Date.current)
    end

    assert_no_difference "Entry.count" do
      assert_nil subscription.reload.generate_transaction!(for_date: 3.days.from_now.to_date)
    end
  end

  test "generate_transaction! books a converted charge rounded to the account currency" do
    uah_account = @family.accounts.create!(name: "Card UAH", balance: 0, currency: "UAH", accountable: CreditCard.new)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 45.385)
    subscription = create_recurring(subscription_state: "subscription", default_account: uah_account,
                                    amount: 2.99, next_expected_date: Date.current)

    entry = subscription.generate_transaction!(for_date: Date.current)

    assert_equal "UAH", entry.currency
    assert_equal BigDecimal("135.70"), entry.amount
  end

  test "generation job creates the overdue period after an unrelated save" do
    subscription = create_recurring(subscription_state: "subscription", default_account: @account,
                                    next_expected_date: 2.days.ago.to_date, expected_day_of_month: 2.days.ago.day)
    subscription.update!(notes: "edited before the cron ran")

    assert_difference "Entry.count", 1 do
      GenerateSubscriptionTransactionsJob.perform_now
    end
    assert subscription.reload.next_expected_date > Date.current
  end

  test "generation job skips subscriptions whose account cannot auto-generate" do
    @account.disable!
    create_recurring(subscription_state: "subscription", default_account: @account, next_expected_date: Date.current)

    assert_no_difference "Entry.count" do
      GenerateSubscriptionTransactionsJob.perform_now
    end
  end

  test "hand-made subscriptions use the long stale threshold and are never auto-deleted" do
    subscription = create_recurring(subscription_state: "subscription", last_occurrence_date: 3.months.ago.to_date)
    refute subscription.should_be_inactive?

    subscription.update!(status: "inactive", inactive_reason: "user")
    dismissed = create_recurring(subscription_state: "dismissed", merchant: merchants(:amazon), status: "inactive")
    pattern = create_recurring(subscription_state: "pattern", name: "Old gym", merchant: nil, status: "inactive")
    RecurringTransaction.where(id: [ subscription.id, dismissed.id, pattern.id ]).update_all(updated_at: 7.months.ago)

    RecurringTransaction::Cleaner.new(@family).remove_old_inactive_transactions

    assert RecurringTransaction.exists?(subscription.id)
    assert RecurringTransaction.exists?(dismissed.id)
    refute RecurringTransaction.exists?(pattern.id)
  end

  test "a yearly subscription is not stale between two yearly charges" do
    yearly = create_recurring(subscription_state: "subscription", billing_cycle: "yearly", expected_month: 7.months.ago.month,
                              last_occurrence_date: 7.months.ago.to_date, next_expected_date: 5.months.from_now.to_date)
    monthly = create_recurring(subscription_state: "subscription", name: "Old gym", merchant: nil, last_occurrence_date: 7.months.ago.to_date)

    RecurringTransaction::Cleaner.new(@family).cleanup_stale_transactions

    assert yearly.reload.active?
    assert monthly.reload.inactive?
    assert yearly.tap { |row| row.last_occurrence_date = 15.months.ago.to_date }.should_be_inactive?
  end

  test "a pattern the user paused is not deleted, so it cannot come back as active" do
    paused = create_recurring(subscription_state: "pattern", status: "inactive", inactive_reason: "user")
    stale = create_recurring(subscription_state: "pattern", name: "Old gym", merchant: nil, status: "inactive", inactive_reason: "stale")
    RecurringTransaction.where(id: [ paused.id, stale.id ]).update_all(updated_at: 7.months.ago)

    RecurringTransaction::Cleaner.new(@family).remove_old_inactive_transactions

    assert RecurringTransaction.exists?(paused.id)
    refute RecurringTransaction.exists?(stale.id)
  end

  test "a manual row whose latest charge fell outside the match window still projects a future date" do
    create_charge(date: 2.months.ago.to_date, amount: 900, merchant: nil, name: "Rent")
    manual = create_recurring(manual: true, merchant: nil, name: "Rent", amount: 900, expected_day_of_month: 2.months.ago.day,
                              last_occurrence_date: 2.months.ago.to_date, next_expected_date: 1.month.ago.to_date)

    identify

    assert manual.reload.next_expected_date > Date.current
  end

  test "cleaner marks stale rows with the stale reason" do
    pattern = create_recurring(subscription_state: "pattern", last_occurrence_date: 3.months.ago.to_date)

    RecurringTransaction::Cleaner.new(@family).cleanup_stale_transactions

    assert pattern.reload.inactive?
    assert_equal "stale", pattern.inactive_reason
  end

  test "clean-up job runs the cleaner for every family with recurring enabled" do
    pattern = create_recurring(subscription_state: "pattern", last_occurrence_date: 3.months.ago.to_date)

    CleanUpRecurringTransactionsJob.perform_now

    assert pattern.reload.inactive?
  end

  private
    # Query fresh rows: the family's association can hold stale in-memory records
    def recurring_rows
      RecurringTransaction.where(family: @family)
    end

    def identify
      RecurringTransaction::Identifier.new(@family).identify_recurring_patterns
    end

    def create_charge(date:, amount:, merchant: @merchant, name: "Netflix")
      create_transaction(account: @account, date: date, amount: amount, name: name, merchant: merchant)
    end

    def create_monthly_charges(amounts:, merchant: @merchant, name: "Netflix")
      amounts.each_with_index do |amount, months_ago|
        create_charge(date: months_ago.months.ago.beginning_of_month + 5.days, amount: amount, merchant: merchant, name: name)
      end
    end

    def create_recurring(**attrs)
      @family.recurring_transactions.create!({
        merchant: @merchant,
        amount: 15.99,
        currency: "USD",
        expected_day_of_month: 6,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 5.days.from_now.to_date,
        status: "active"
      }.merge(attrs))
    end
end
