require "test_helper"

class RecurringTransaction::ReconcileJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    Rails.cache.delete(RecurringTransaction::ReconcileJob.debounce_key(@family.id))
  end

  test "runs the reconciler for the family" do
    reconciler = mock
    reconciler.expects(:reconcile).once
    RecurringTransaction::Reconciler.expects(:new).with(@family).returns(reconciler)

    RecurringTransaction::ReconcileJob.perform_now(@family.id)
  end

  test "runs while recurring transactions are disabled" do
    @family.update!(recurring_transactions_disabled: true)
    reconciler = mock
    reconciler.expects(:reconcile).once
    RecurringTransaction::Reconciler.expects(:new).with(@family).returns(reconciler)

    RecurringTransaction::ReconcileJob.perform_now(@family.id)
  end

  test "schedule_for enqueues even while recurring transactions are disabled" do
    @family.update!(recurring_transactions_disabled: true)

    assert_enqueued_with(job: RecurringTransaction::ReconcileJob) do
      RecurringTransaction.reconcile_charges_for(@family)
    end
  end

  test "exits when another run holds the advisory lock" do
    # A second database session holds the lock, as a concurrent job would
    other = PG.connect(**ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact.slice(:host, :port, :user, :password, :dbname))
    key = Digest::MD5.hexdigest(RecurringTransaction::ReconcileJob.lock_name(@family.id)).to_i(16) % (2**31)
    other.exec_params("SELECT pg_advisory_lock($1)", [ key ])

    RecurringTransaction::Reconciler.expects(:new).never

    RecurringTransaction::ReconcileJob.perform_now(@family.id)
  ensure
    if other
      other.exec_params("SELECT pg_advisory_unlock($1)", [ key ])
      other.close
    end
  end

  test "a job superseded by a newer schedule does nothing" do
    scheduled_at = Time.current.to_f
    # The test cache is a null store
    Rails.cache.stubs(:read).with(RecurringTransaction::ReconcileJob.debounce_key(@family.id)).returns(scheduled_at + 10)

    RecurringTransaction::Reconciler.expects(:new).never

    RecurringTransaction::ReconcileJob.perform_now(@family.id, scheduled_at)
  end

  test "the sync complete event schedules reconciliation before pattern identification" do
    sequence = sequence("post sync")
    RecurringTransaction.expects(:reconcile_charges_for).with(@family).in_sequence(sequence)
    RecurringTransaction.expects(:identify_patterns_for).with(@family).in_sequence(sequence)
    @family.stubs(:broadcast_replace)
    @family.stubs(:broadcast_replace_to)

    Family::SyncCompleteEvent.new(@family).broadcast
  end
end
