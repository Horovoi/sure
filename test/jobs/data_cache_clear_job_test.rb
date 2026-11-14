require "test_helper"

class DataCacheClearJobTest < ActiveJob::TestCase
  test "clears shared market data and resyncs every family, not only the requester" do
    family = families(:dylan_family)
    other_family = families(:empty)
    Sync.where(syncable_type: "Family").delete_all
    assert ExchangeRate.exists?
    assert Security::Price.exists?

    assert_enqueued_jobs Family.count, only: SyncJob do
      DataCacheClearJob.perform_now(family)
    end

    assert_not ExchangeRate.exists?
    assert_not Security::Price.exists?
    assert family.syncs.incomplete.exists?
    assert other_family.syncs.incomplete.exists?, "other families lose the shared market data too"
  end
end
