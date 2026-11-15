require "test_helper"

class DestroyJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:depository)
    @account.mark_for_deletion!
  end

  test "an account whose destroy succeeds is removed and nothing is logged" do
    assert_no_difference -> { DebugLogEntry.count } do
      assert_difference "Account.count", -1 do
        DestroyJob.perform_now(@account)
      end
    end
  end

  test "a deadlock enqueues the job again and keeps the account pending_deletion" do
    @account.stubs(:destroy).raises(ActiveRecord::Deadlocked, "deadlock detected")

    assert_no_difference -> { DebugLogEntry.count } do
      assert_enqueued_with(job: DestroyJob, args: [ @account ]) do
        DestroyJob.perform_now(@account)
      end
    end

    assert_equal "pending_deletion", @account.reload.status
  end

  test "an account whose destroy deadlocks once succeeds on the retry" do
    Account.any_instance.expects(:destroy).twice.raises(ActiveRecord::Deadlocked, "deadlock detected").then.returns(true)

    assert_no_difference -> { DebugLogEntry.count } do
      assert_performed_jobs 2, only: DestroyJob do
        DestroyJob.perform_later(@account)
      end
    end
  end

  test "a deadlock that outlasts the attempts restores the account and records an error" do
    Account.any_instance.stubs(:destroy).raises(ActiveRecord::Deadlocked, "deadlock detected")

    assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
      perform_enqueued_jobs { DestroyJob.perform_later(@account) }
    end

    entry = DebugLogEntry.recent.first
    assert_equal "destroy", entry.category
    assert_equal "error", entry.level
    assert_equal "ActiveRecord::Deadlocked", entry.metadata["error_class"]
    assert_equal DestroyJob::ATTEMPTS, entry.metadata["attempts"]
    assert_equal @account, entry.account
    assert_equal "disabled", @account.reload.status
  end

  test "any other error restores the account at once, without a retry" do
    @account.stubs(:destroy).raises(ActiveRecord::InvalidForeignKey, "boom")

    assert_no_enqueued_jobs(only: DestroyJob) do
      assert_difference -> { DebugLogEntry.where(source: "DestroyJob", category: "destroy").count }, 1 do
        DestroyJob.perform_now(@account)
      end
    end

    entry = DebugLogEntry.recent.first
    assert_equal "ActiveRecord::InvalidForeignKey", entry.metadata["error_class"]
    assert_equal "boom", entry.metadata["error_message"]
    assert_equal @account.family, entry.family
    assert entry.metadata["backtrace"].present?
    assert_equal "disabled", @account.reload.status
  end

  test "a destroy halted by a callback is recorded as RecordNotDestroyed" do
    @account.stubs(:destroy).returns(false)

    DestroyJob.perform_now(@account)

    assert_equal "ActiveRecord::RecordNotDestroyed", DebugLogEntry.recent.first.metadata["error_class"]
    assert_equal "disabled", @account.reload.status
  end

  test "a deadlock after the row is gone is recorded instead of retried" do
    # The real destroy (a bare delete would trip the goal_accounts foreign key), then a deadlock in a later step
    @account.define_singleton_method(:destroy) do
      super()
      raise ActiveRecord::Deadlocked, "deadlock detected"
    end

    assert_no_enqueued_jobs(only: DestroyJob) do
      assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
        DestroyJob.perform_now(@account)
      end
    end

    entry = DebugLogEntry.recent.first
    assert_equal "ActiveRecord::Deadlocked", entry.metadata["error_class"]
    assert_nil entry.account_id
    assert_equal @account.family_id, entry.family_id
    assert_not Account.exists?(@account.id)
  end

  test "a job that runs after the reaper restored the account does nothing" do
    @account.restore!

    assert_no_difference [ "Account.count", "DebugLogEntry.count" ] do
      DestroyJob.perform_now(@account)
    end

    assert @account.reload.disabled?
  end

  test "a provider item's failed destroy clears scheduled_for_deletion" do
    item = plaid_items(:one)
    item.update_column(:scheduled_for_deletion, true)
    item.stubs(:destroy).raises(StandardError, "destroy failed")

    assert_difference -> { DebugLogEntry.where(family: item.family, source: "DestroyJob").count }, 1 do
      DestroyJob.perform_now(item)
    end

    assert_not item.reload.scheduled_for_deletion?
  end

  test "a failure is also sent to the Rails log" do
    @account.stubs(:destroy).raises(StandardError, "destroy failed")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/DestroyJob failed for Account #{@account.id}: StandardError: destroy failed/)).once

    DestroyJob.perform_now(@account)
  end
end
