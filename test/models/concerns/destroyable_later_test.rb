require "test_helper"

class DestroyableLaterTest < ActiveSupport::TestCase
  class Item < LunchflowItem
    include DestroyableLater
  end

  setup do
    @item = Item.find(lunchflow_items(:one).id)
  end

  test "flags the item and enqueues the destroy" do
    DestroyJob.expects(:perform_later).with(@item).returns(true)

    @item.destroy_later

    assert @item.reload.scheduled_for_deletion?
  end

  test "restores the flag when the enqueue raises" do
    DestroyJob.expects(:perform_later).raises(RedisClient::CannotConnectError)

    assert_raises(RedisClient::CannotConnectError) { @item.destroy_later }

    assert_not @item.reload.scheduled_for_deletion?
  end

  test "restores the flag when the enqueue returns false" do
    DestroyJob.expects(:perform_later).returns(false)

    assert_equal false, @item.destroy_later

    assert_not @item.reload.scheduled_for_deletion?
  end

  test "an item already flagged is enqueued again and keeps its flag on failure" do
    @item.update_column(:scheduled_for_deletion, true)
    DestroyJob.expects(:perform_later).returns(false)

    @item.destroy_later

    assert @item.reload.scheduled_for_deletion?
  end
end
