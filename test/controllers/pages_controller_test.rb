require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "dashboard renders sankey chart with subcategories" do
    # Create parent category with subcategory
    parent_category = @family.categories.create!(name: "Shopping", classification: "expense", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", classification: "expense", parent: parent_category, color: "#33FF57")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path
    assert_response :ok
    assert_select "[data-controller='sankey-chart']"
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
    end
  end

  test "changelog with nil release notes" do
    # Mock the GitHub provider to return nil (simulating API failure or no releases)
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Release notes unavailable"
    assert_select "a[href='https://github.com/we-promise/sure/releases']"
  end

  test "changelog with incomplete release notes" do
    # Mock the GitHub provider to return incomplete data (missing some fields)
    github_provider = mock
    incomplete_data = {
      avatar: nil,
      username: "maybe-finance",
      name: "Test Release",
      published_at: nil,
      body: nil
    }
    github_provider.expects(:fetch_latest_release_notes).returns(incomplete_data)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Test Release"
    # Should not crash even with nil values
  end

  test "dashboard preferences merge collapsed sections and replace the section order" do
    patch dashboard_preferences_url, params: { preferences: { collapsed_sections: { net_worth_chart: true } } }, as: :json
    patch dashboard_preferences_url, params: { preferences: { collapsed_sections: { balance_sheet: true }, section_order: %w[balance_sheet net_worth_chart] } }, as: :json

    assert_response :success
    preferences = @user.reload.preferences
    assert_equal({ "net_worth_chart" => true, "balance_sheet" => true }, preferences["collapsed_sections"])
    assert_equal %w[balance_sheet net_worth_chart], preferences["section_order"]
  end

  test "dashboard preferences ignore keys that are not dashboard settings" do
    patch dashboard_preferences_url, params: { preferences: { collapsed_sections: { balance_sheet: true }, show_ai_sidebar: false } }, as: :json

    assert_response :success
    assert_not @user.reload.preferences.key?("show_ai_sidebar")
  end

  test "malformed dashboard preferences are a bad request, not an error" do
    patch dashboard_preferences_url, params: { preferences: "nope" }, as: :json

    assert_response :bad_request
  end
end
