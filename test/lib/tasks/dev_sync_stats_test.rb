require "test_helper"

load Rails.root.join("lib/tasks/dev_sync_stats.rake") unless defined?(DevSyncStatsHelpers)

class DevSyncStatsTest < ActiveSupport::TestCase
  test "fake stats never overwrite the status of a sync in flight" do
    account = accounts(:depository)
    account.syncs.delete_all
    in_flight = account.syncs.create!
    in_flight.start!

    Account.stubs(:all).returns([ account ])
    capture_io { DevSyncStatsHelpers.generate_fake_stats_for_items(Account, "plaid") }

    assert in_flight.reload.syncing?, "a running sync keeps its status"
    completed = account.syncs.completed.sole
    assert completed.sync_stats.present?
    assert_not_nil completed.completed_at
  end
end
