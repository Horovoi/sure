require "test_helper"

class Settings::AiToolAuditsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
  end

  test "an admin sees the family's tool calls, newest first, with the before state and record links" do
    sign_in @admin

    get settings_ai_tool_audits_url

    assert_response :success
    assert_select "#ai-tool-audits li", 2
    assert_select "#ai-tool-audits li:first-child", text: /update_category/
    assert_select "#ai-tool-audits", text: /Food &amp; Drink|Food & Drink/
    assert_select "a[href=?]", edit_category_path(categories(:food_and_drink))
    assert_select "#ai-tool-audits", text: /Built-in chat/
    assert_select "#ai-tool-audits", text: /claude-code/
  end

  test "the list shows rows of the own family only" do
    sign_in @admin

    get settings_ai_tool_audits_url

    assert_select "##{ActionView::RecordIdentifier.dom_id(ai_tool_audits(:other_family_call))}", 0
    assert_no_match "get_transactions", response.body
  end

  test "the writes-only filter leaves out reads" do
    sign_in @admin

    get settings_ai_tool_audits_url(writes: "1")

    assert_select "#ai-tool-audits li", 1
    assert_select "#ai-tool-audits", text: /update_category/
    assert_select "##{ActionView::RecordIdentifier.dom_id(ai_tool_audits(:read_call))}", 0
  end

  test "the tool filter keeps one tool" do
    sign_in @admin

    get settings_ai_tool_audits_url(tool: "get_accounts")

    assert_select "#ai-tool-audits li", 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(ai_tool_audits(:read_call))}", 1
  end

  test "an unknown tool filter is ignored" do
    sign_in @admin

    get settings_ai_tool_audits_url(tool: "'; DROP TABLE ai_tool_audits; --")

    assert_response :success
    assert_select "#ai-tool-audits li", 2
  end

  test "a long-running row shows as interrupted" do
    ai_tool_audits(:write_call).update_columns(status: "running", finished_at: nil)
    sign_in @admin

    get settings_ai_tool_audits_url

    assert_select "#ai-tool-audits", text: /Interrupted/
  end

  test "a member without admin rights gets 404" do
    sign_in users(:family_member)

    get settings_ai_tool_audits_url

    assert_response :not_found
  end

  test "the settings nav links the page for an admin" do
    sign_in @admin

    get settings_preferences_url

    assert_select "a[href=?]", settings_ai_tool_audits_path
  end

  test "the settings nav hides the page from a member" do
    sign_in users(:family_member)

    get settings_preferences_url

    assert_select "a[href=?]", settings_ai_tool_audits_path, 0
  end
end
