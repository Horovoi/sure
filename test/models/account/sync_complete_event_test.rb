require "test_helper"

class Account::SyncCompleteEventTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    Current.reset
  end

  # The sync toast refreshes the account page once the user is idle; a refresh on
  # the account stream reloaded the page under an open form and rendered it twice.
  test "does not broadcast a page refresh on the account stream" do
    actions = capture_turbo_stream_broadcasts(@account) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["action"] }

    assert_not_includes actions, "refresh"
  end

  test "still replaces the account row and its sidebar groups" do
    targets = capture_turbo_stream_broadcasts(@account.family) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "account_#{@account.id}"
    assert_includes targets, "all_depository"
    assert_includes targets, "mobile_all_depository"
  end

  test "a manual account sends the family sync toast" do
    targets = capture_turbo_stream_broadcasts(@account.family) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "sync-toast"
  end

  test "a linked account leaves the family broadcast to its provider item" do
    linked = accounts(:connected)
    assert linked.linked?

    targets = capture_turbo_stream_broadcasts(linked.family) do
      Account::SyncCompleteEvent.new(linked).broadcast
    end.map { |stream| stream["target"] }

    assert_not_includes targets, "sync-toast"
  end
end
