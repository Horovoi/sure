require "test_helper"

class SyncHourlyJobTest < ActiveJob::TestCase
  test "syncs all active items for each hourly syncable class" do
    enable_bank_connections

    mock_item = mock("coinstats_item")
    mock_item.expects(:sync_later).once

    mock_relation = mock("active_relation")
    mock_relation.stubs(:find_each).yields(mock_item)

    CoinstatsItem.expects(:active).returns(mock_relation)

    SyncHourlyJob.perform_now
  end

  test "continues syncing other items when one fails" do
    enable_bank_connections

    failing_item = mock("failing_item")
    failing_item.expects(:sync_later).raises(StandardError.new("Test error"))
    failing_item.stubs(:id).returns(1)

    success_item = mock("success_item")
    success_item.expects(:sync_later).once

    mock_relation = mock("active_relation")
    mock_relation.stubs(:find_each).multiple_yields([ failing_item ], [ success_item ])

    CoinstatsItem.expects(:active).returns(mock_relation)

    assert_nothing_raised do
      SyncHourlyJob.perform_now
    end
  end

  test "syncs only the hourly providers that are switched on" do
    enable_bank_connections(:lunchflow, :plaid)

    CoinstatsItem.expects(:active).never
    LunchflowItem.expects(:active).never
    PlaidItem.expects(:active).never

    SyncHourlyJob.perform_now
  end

  test "reads the hourly providers from the registry" do
    hourly = BankConnections::Provider.new(key: "testbank", association: :testbank_items, item_class_name: "LunchflowItem",
      account_class_name: "LunchflowAccount", label: "Test", description: nil, docs_url: nil, hourly: true,
      balance_includes_pending: false, settings_partial: nil, config_keys: [], generic_listing: false)
    BankConnections.stubs(:enabled_providers).returns([ hourly ])

    item = mock("item")
    item.expects(:sync_later).once
    relation = mock("relation")
    relation.stubs(:find_each).yields(item)
    LunchflowItem.expects(:active).returns(relation)
    CoinstatsItem.expects(:active).never

    SyncHourlyJob.perform_now
  end

  test "skips provider items when bank connections are disabled" do
    CoinstatsItem.expects(:active).never
    CoinstatsItem.any_instance.expects(:sync_later).never

    SyncHourlyJob.perform_now
  end
end
