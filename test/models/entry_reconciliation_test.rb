require "test_helper"

# w3-toolstrx reconciliation-status: Entry#reconciled_status and its bulk update
class EntryReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @manual = accounts(:depository)
    @synced = accounts(:connected) # linked through a Plaid account
  end

  test "a new entry is unreconciled" do
    assert create_transaction(account: @manual).unreconciled?
  end

  test "a value outside the three is invalid" do
    entry = create_transaction(account: @manual)
    entry.reconciled_status = "approved"

    assert_not entry.valid?
    assert entry.errors.of_kind?(:reconciled_status, :inclusion)
  end

  test "the badge cycle goes unreconciled, cleared, reconciled and back" do
    entry = create_transaction(account: @manual)

    assert_equal %w[cleared reconciled unreconciled], 3.times.map { entry.advance_reconciled_status! && entry.reconciled_status }
  end

  test "advancing the mark locks nothing and is not a user edit" do
    entry = create_transaction(account: @manual)
    entry.advance_reconciled_status!

    assert_empty entry.reload.locked_attributes
    assert_not entry.user_modified?
  end

  test "only transactions of manual accounts are reconcilable" do
    assert create_transaction(account: @manual).reconcilable?
    assert_not create_transaction(account: @synced).reconcilable?
    assert_not create_valuation(account: @manual, date: 20.days.ago.to_date).reconcilable?
  end

  test "needs_reconciliation is unreconciled and cleared" do
    open = create_transaction(account: @manual)
    cleared = create_transaction(account: @manual, reconciled_status: "cleared")
    done = create_transaction(account: @manual, reconciled_status: "reconciled")

    ids = Entry.where(id: [ open, cleared, done ].map(&:id)).needs_reconciliation.ids
    assert_equal [ open.id, cleared.id ].sort, ids.sort
  end

  test "bulk update sets the mark on manual transactions and skips the rest" do
    manual_entry = create_transaction(account: @manual)
    synced_entry = create_transaction(account: @synced)
    valuation = create_valuation(account: @manual, date: 21.days.ago.to_date)
    already = create_transaction(account: @manual, reconciled_status: "cleared")

    updated = Entry.where(id: [ manual_entry, synced_entry, valuation, already ].map(&:id))
      .bulk_update!({ reconciled_status: "cleared" })

    assert_equal 1, updated
    assert manual_entry.reload.cleared?
    assert synced_entry.reload.unreconciled?
    assert valuation.reload.unreconciled?
  end

  test "a reconcile-only bulk update locks nothing; with an edit the edit is locked" do
    entry = create_transaction(account: @manual)
    Entry.where(id: entry.id).bulk_update!({ reconciled_status: "reconciled" })

    entry.reload
    assert entry.reconciled?
    assert_empty entry.locked_attributes
    assert_not entry.user_modified?

    Entry.where(id: entry.id).bulk_update!({ notes: "Checked", reconciled_status: "cleared" })

    entry.reload
    assert entry.cleared?
    assert entry.locked?(:notes)
    assert_not entry.locked?(:reconciled_status)
    assert entry.user_modified?
  end

  test "bulk update refuses an unknown status before changing anything" do
    entry = create_transaction(account: @manual)

    assert_raises(ArgumentError) do
      Entry.where(id: entry.id).bulk_update!({ notes: "Changed", reconciled_status: "approved" })
    end
    assert_nil entry.reload.notes
  end
end
