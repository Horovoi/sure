require "test_helper"

class CurrentSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @session = @user.sessions.order(created_at: :desc).first
  end

  test "stores an allowed tab key and value" do
    put current_session_url, params: { current_session: { tab_key: "account_sidebar_tab", tab_value: "liability" } }

    assert_response :ok
    assert_equal "liability", @session.reload.get_preferred_tab("account_sidebar_tab")
  end

  test "ignores an unknown tab key" do
    put current_session_url, params: { current_session: { tab_key: "accounts_sidebar_tab", tab_value: "asset" } }

    assert_response :ok
    assert_nil @session.reload.data["tab_preferences"]
  end

  test "ignores an unknown tab value" do
    @session.set_preferred_tab("account_sidebar_tab", "all")

    put current_session_url, params: { current_session: { tab_key: "account_sidebar_tab", tab_value: "<script>" } }

    assert_response :ok
    assert_equal({ "account_sidebar_tab" => "all" }, @session.reload.data["tab_preferences"])
  end

  test "a stored tab that is no longer allowed renders the asset tab" do
    @session.update_column(:data, { "tab_preferences" => { "account_sidebar_tab" => "bogus" } })

    get root_url

    assert_response :ok
    assert_select "[data-testid='account-sidebar-tabs'] div[data-id='asset']:not(.hidden)"
    assert_select "[data-testid='account-sidebar-tabs'] div[data-id='liability'].hidden"
    assert_select "[data-testid='account-sidebar-tabs'] div[data-id='bogus']", count: 0
  end

  test "a stored allowed tab is restored on the next page" do
    put current_session_url, params: { current_session: { tab_key: "account_sidebar_tab", tab_value: "liability" } }

    get root_url

    assert_response :ok
    assert_select "[data-testid='account-sidebar-tabs'] div[data-id='liability']:not(.hidden)"
    assert_select "[data-testid='account-sidebar-tabs'] div[data-id='asset'].hidden"
  end
end
