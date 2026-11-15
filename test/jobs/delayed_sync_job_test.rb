require "test_helper"

class DelayedSyncJobTest < ActiveJob::TestCase
  test "asks for a sync of the item, but not of one being deleted" do
    item = monobank_items(:one)

    assert_difference -> { item.syncs.count }, 1 do
      DelayedSyncJob.perform_now(item)
    end

    item.update!(scheduled_for_deletion: true)
    assert_no_difference -> { item.syncs.count } do
      DelayedSyncJob.perform_now(item)
    end
  end
end
