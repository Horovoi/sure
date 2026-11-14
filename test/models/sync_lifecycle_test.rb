require "test_helper"

# Regression tests for the sync state machine: claim, rerun, finalization and reaping.
class SyncLifecycleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:depository)
  end

  test "a sync can be claimed by only one worker" do
    sync = Sync.create!(syncable: @account)
    other_copy = Sync.find(sync.id)

    Account.any_instance.expects(:perform_sync).once

    sync.perform
    other_copy.perform # a redelivered job holding a stale copy

    assert_equal "completed", sync.reload.status
  end

  test "a sync requested while one is running is not dropped: it reruns once" do
    running = Sync.create!(syncable: @account, status: :syncing, syncing_at: Time.current)

    assert_no_difference "Sync.count" do
      @account.sync_later
    end
    assert running.reload.rerun_requested?

    Account.any_instance.stubs(:perform_post_sync)
    Account.any_instance.stubs(:broadcast_sync_complete)

    assert_enqueued_with(job: SyncJob) do
      running.finalize_if_all_children_finalized
    end
    assert_equal 1, @account.syncs.where(status: "pending").count
  end

  test "post-sync runs exactly once however often finalization is called" do
    sync = Sync.create!(syncable: @account, status: :syncing, syncing_at: Time.current)

    Account.any_instance.expects(:perform_post_sync).once
    Account.any_instance.expects(:broadcast_sync_complete).once

    3.times { Sync.find(sync.id).finalize_if_all_children_finalized }

    assert_equal "completed", sync.reload.status
    assert sync.finalized_at.present?
  end

  test "a guard failure still finalizes the parent" do
    family_sync = Sync.create!(syncable: families(:dylan_family), status: :syncing, syncing_at: Time.current)
    child = Sync.create!(syncable: @account, parent: family_sync)
    @account.update_columns(status: "pending_deletion")

    Family.any_instance.stubs(:perform_post_sync)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.stubs(:perform_post_sync)
    Account.any_instance.stubs(:broadcast_sync_complete)

    child.perform

    assert_equal "failed", child.reload.status
    assert_equal "Syncable record is scheduled for deletion", child.error
    assert_equal "failed", family_sync.reload.status
  end

  test "a stale child fails its parent instead of counting as success" do
    family_sync = Sync.create!(syncable: families(:dylan_family), status: :syncing, syncing_at: 2.hours.ago, created_at: 2.hours.ago)
    Sync.create!(syncable: @account, parent: family_sync, status: :syncing, syncing_at: 2.hours.ago, created_at: 2.hours.ago)

    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.stubs(:perform_post_sync)
    Account.any_instance.stubs(:broadcast_sync_complete)

    assert_includes [ 1, 2 ], Sync.clean

    # Reaped first, the parent is stale; if the child is reaped first, finalizing it fails
    # the still-syncing parent. Either way the parent finishes, unsuccessfully, exactly once.
    assert_includes %w[stale failed], family_sync.reload.status
    assert family_sync.finalized_at.present?
  end

  test "the reaper leaves fresh syncs alone" do
    Sync.create!(syncable: @account, status: :syncing, syncing_at: 1.minute.ago)
    assert_equal 0, Sync.clean
  end

  test "a family sync creates all child syncs before any job is enqueued" do
    family = families(:dylan_family)
    family_sync = Sync.create!(syncable: family, status: :syncing, syncing_at: Time.current)

    Family::Syncer.new(family).perform_sync(family_sync)

    child_types = family_sync.children.map(&:syncable_type).uniq
    assert_equal [ "Account" ], child_types, "bank-connection items are skipped while bank connections are off"
    assert_equal family.accounts.visible.manual.count, family_sync.children.count
  end
end
