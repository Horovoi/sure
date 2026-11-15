require "test_helper"

class BalanceSheet::SyncStatusMonitorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @monitor = BalanceSheet::SyncStatusMonitor.new(@family)
  end

  test "asks the cache once for any number of accounts" do
    Rails.cache.expects(:fetch).once.returns(Set[accounts(:depository).id])

    assert @monitor.account_syncing?(accounts(:depository))
    assert_not @monitor.account_syncing?(accounts(:credit_card))
    assert @monitor.syncing?
  end

  test "reports a visible account sync as syncing" do
    Sync.create!(syncable: accounts(:depository))

    assert @monitor.account_syncing?(accounts(:depository))
    assert_not @monitor.account_syncing?(accounts(:credit_card))
  end
end
