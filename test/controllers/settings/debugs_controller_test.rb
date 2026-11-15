require "test_helper"

class Settings::DebugsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @entry = DebugLogEntry.create!(
      category: "sync",
      level: "error",
      message: "Sync failed: could not import",
      source: "Sync",
      provider_key: "manual",
      family: families(:dylan_family),
      account: accounts(:depository),
      user: users(:family_admin),
      metadata: { sync_id: SecureRandom.uuid }
    )
  end

  test "super admins see the debug log" do
    sign_in users(:sure_support_staff)

    get settings_debug_url

    assert_response :success
    assert_match "Debug event log", response.body
    assert_match @entry.message, response.body
  end

  test "the log table can be expanded into a larger dialog" do
    sign_in users(:sure_support_staff)

    get settings_debug_url

    assert_response :success
    assert_select "[data-controller=expandable]", 1
    assert_select "button[data-action=?]", "click->expandable#open", count: 1
    # The expanded copy is the same table, so both render every entry
    assert_select "table tbody tr", 2
    assert_select "dialog[data-expandable-target=dialog] table tbody tr", 1
  end

  test "no expand trigger when there are no entries" do
    sign_in users(:sure_support_staff)
    DebugLogEntry.delete_all

    get settings_debug_url

    assert_response :success
    assert_select "button[data-action=?]", "click->expandable#open", count: 0
    assert_select "dialog[data-expandable-target=dialog]", 0
  end

  test "filters by level, category and date" do
    sign_in users(:sure_support_staff)
    DebugLogEntry.create!(category: "stale_work", level: "warn", message: "Should be filtered out", source: "StaleWorkReaperJob")

    get settings_debug_url, params: { level: "error", category: "sync", start_date: Date.current.iso8601, end_date: Date.current.iso8601 }

    assert_response :success
    assert_match @entry.message, response.body
    assert_no_match "Should be filtered out", response.body
  end

  test "filters by provider key and account" do
    sign_in users(:sure_support_staff)
    DebugLogEntry.create!(category: "sync", level: "error", message: "Other account", source: "Sync", account: accounts(:investment))

    get settings_debug_url, params: { account_id: accounts(:depository).id, provider_key: "manual" }

    assert_response :success
    assert_match @entry.message, response.body
    assert_no_match "Other account", response.body
  end

  test "ignores invalid uuid and date filters" do
    sign_in users(:sure_support_staff)

    get settings_debug_url, params: { family_id: "not-a-uuid", start_date: "yesterday" }

    assert_response :success
    assert_match @entry.message, response.body
  end

  test "admins get a 404" do
    sign_in users(:family_admin)

    get settings_debug_url

    assert_response :not_found
  end

  test "members get a 404" do
    sign_in users(:family_member)

    get settings_debug_url

    assert_response :not_found
  end

  test "the settings nav has no debug link" do
    sign_in users(:sure_support_staff)

    get settings_debug_url

    assert_select "nav a[href=?]", settings_debug_path, count: 0
  end
end
