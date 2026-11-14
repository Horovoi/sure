require "test_helper"

class IdentifyRecurringTransactionsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @family.syncs.destroy_all
    @family.accounts.each { |account| account.syncs.destroy_all }
    Rails.cache.delete("recurring_transaction_identify:#{@family.id}")
  end

  test "runs subscription detection once per identification" do
    RecurringTransaction::SubscriptionDetector.expects(:detect_for_family).with(@family).once

    IdentifyRecurringTransactionsJob.perform_now(@family.id, Time.current.to_f)
  end

  test "requeues when another identification holds the lock" do
    IdentifyRecurringTransactionsJob.any_instance.stubs(:with_advisory_lock).returns(false)
    scheduled_at = Time.current.to_f

    assert_enqueued_with(job: IdentifyRecurringTransactionsJob, args: [ @family.id, scheduled_at ]) do
      IdentifyRecurringTransactionsJob.perform_now(@family.id, scheduled_at)
    end
  end

  test "debounce marker outlives queue latency" do
    Rails.cache.expects(:write).with("recurring_transaction_identify:#{@family.id}", anything, expires_in: IdentifyRecurringTransactionsJob::DEBOUNCE_KEY_TTL)

    IdentifyRecurringTransactionsJob.schedule_for(@family)

    assert IdentifyRecurringTransactionsJob::DEBOUNCE_KEY_TTL >= 1.hour
  end
end
