require "test_helper"

class Family::SyncCompleteEventTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    Current.reset
  end

  test "broadcasts the sync toast to the family stream" do
    streams = capture_turbo_stream_broadcasts(@family) do
      Family::SyncCompleteEvent.new(@family).broadcast
    end

    toast = streams.find { |stream| stream["target"] == "sync-toast" }
    assert toast, "expected a sync-toast broadcast"
    assert_equal "replace", toast["action"]
    assert_includes toast.to_html, I18n.t("shared.sync_toast.refresh")
    assert_includes toast.to_html, %(aria-label="#{I18n.t("shared.sync_toast.close")}")
  end

  test "still replaces the dashboard balance sheet and net worth chart" do
    targets = capture_turbo_stream_broadcasts(@family) do
      Family::SyncCompleteEvent.new(@family).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "balance-sheet"
    assert_includes targets, "net-worth-chart"
  end

  test "a manual account sync still schedules recurring transaction identification" do
    account = accounts(:depository)
    assert account.unlinked?

    assert_enqueued_with(job: IdentifyRecurringTransactionsJob) do
      Account::SyncCompleteEvent.new(account).broadcast
    end
  end

  test "a failing toast broadcast does not stop recurring identification" do
    @family.stubs(:broadcast_replace_to).raises(StandardError, "boom")

    assert_enqueued_with(job: IdentifyRecurringTransactionsJob) do
      Family::SyncCompleteEvent.new(@family).broadcast
    end
  end
end
