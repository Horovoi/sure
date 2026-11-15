require "test_helper"

class SyncWarningThresholdTest < ActiveSupport::TestCase
  test "an account warns after 10 syncs a day" do
    account = accounts(:depository)
    11.times { Sync.create!(syncable: account) }

    Sentry.expects(:capture_exception).with { |error, **| error.message.include?("exceeded 10 syncs") }.once
    Sync.create!(syncable: account).start!
  end

  test "an hourly provider's item warns only after 100 syncs a day" do
    item = coinstats_item
    50.times { Sync.create!(syncable: item) }

    Sentry.expects(:capture_exception).never
    Sync.create!(syncable: item).start!

    50.times { Sync.create!(syncable: item) }
    Sentry.expects(:capture_exception).with { |error, **| error.message.include?("exceeded 100 syncs") }.once
    Sync.create!(syncable: item).start!
  end

  private
    def coinstats_item
      families(:dylan_family).coinstats_items.create!(name: "Wallets", api_key: "key")
    end
end
