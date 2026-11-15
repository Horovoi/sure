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

  test "the upstream changelog and feedback pages are gone" do
    get "/changelog"
    assert_response :not_found

    get "/feedback"
    assert_response :not_found
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
