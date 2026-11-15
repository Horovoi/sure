require "test_helper"

class DebugLogEntryTest < ActiveSupport::TestCase
  test "requires category, level, message and source" do
    entry = DebugLogEntry.new

    assert_not entry.valid?
    %i[category level message source].each do |attribute|
      assert entry.errors.added?(attribute, :blank), "expected #{attribute} to be required"
    end
  end

  test "rejects an unknown level" do
    entry = DebugLogEntry.new(category: "sync", level: "fatal", message: "x", source: "Test")

    assert_not entry.valid?
    assert entry.errors.added?(:level, :inclusion, value: "fatal")
  end

  test "the database rejects an unknown level too" do
    entry = DebugLogEntry.create!(category: "sync", level: "info", message: "x", source: "Test")

    assert_raises(ActiveRecord::StatementInvalid) do
      entry.update_column(:level, "fatal")
    end
  end

  test "log! takes the family from the account and the provider key from the provider" do
    entry = DebugLogEntry.log!(
      category: "provider_sync",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      account: accounts(:depository),
      provider: :twelve_data,
      metadata: { test: true }
    )

    assert entry.persisted?
    assert_equal "twelve_data", entry.provider_key
    assert_equal accounts(:depository), entry.account
    assert_equal accounts(:depository).family, entry.family
    assert_equal({ "test" => true }, entry.metadata)
  end

  test "log! takes the family from the user" do
    entry = DebugLogEntry.log!(category: "auth", level: "info", message: "x", source: "Test", user_id: users(:family_admin).id)

    assert_equal users(:family_admin), entry.user
    assert_equal users(:family_admin).family, entry.family
  end

  test "capture swallows errors and returns nil" do
    assert_no_difference "DebugLogEntry.count" do
      assert_nil DebugLogEntry.capture(category: "sync", level: "nonsense", message: "x", source: "Test")
    end
  end

  test "capture does not raise when the insert fails in the database" do
    DebugLogEntry.stubs(:create!).raises(ActiveRecord::StatementInvalid, "boom")

    assert_nothing_raised do
      assert_nil DebugLogEntry.capture(category: "sync", level: "error", message: "x", source: "Test")
    end
  end

  test "a failed capture leaves the caller's transaction usable" do
    family = families(:dylan_family)

    ActiveRecord::Base.transaction do
      # jsonb rejects a NUL character, so the insert fails in Postgres, not in validation
      assert_nil DebugLogEntry.capture(category: "sync", level: "error", message: "x", source: "Test", metadata: { a: "bad\u0000byte" })
      family.update!(name: "Still writable")
    end

    assert_equal "Still writable", family.reload.name
  end

  test "secret metadata keys are filtered" do
    entry = DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "x",
      source: "Test",
      metadata: { access_token: "abc", password: "hunter2", nested: { api_secret: "s" }, ticker: "AAPL" }
    )

    assert_equal "[FILTERED]", entry.metadata["access_token"]
    assert_equal "[FILTERED]", entry.metadata["password"]
    assert_equal "[FILTERED]", entry.metadata.dig("nested", "api_secret")
    assert_equal "AAPL", entry.metadata["ticker"]
  end

  test "a long message is truncated" do
    entry = DebugLogEntry.capture(category: "sync", level: "error", message: "a" * 20_000, source: "Test")

    assert_equal DebugLogEntry::MESSAGE_LIMIT, entry.message.length
  end
end
