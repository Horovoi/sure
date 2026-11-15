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

    get root_path(cashflow_show_subcategories: "1")
    assert_response :ok
    assert_select "[data-controller='sankey-chart']"

    # One payload for both modes: the chart drops the subcategory column itself
    chart = css_select("#cashflowSankeyChart").sole
    data = JSON.parse(chart["data-sankey-chart-data-value"])
    ids = data["nodes"].map { |node| node["id"] }
    assert_includes ids, "expense_#{parent_category.id}"
    assert_includes ids, "expense_sub_#{subcategory.id}"
    assert_includes ids, "expense_sub_#{parent_category.id}_other"
    assert_equal "true", chart["data-sankey-chart-show-subcategories-value"]
    assert_equal subcategory.name, data["nodes"].find { |node| node["id"] == "expense_sub_#{subcategory.id}" }["filter_value"]
    assert_select "#cashflowSankeyChartFullscreen"
  end

  test "the Sankey carries the custom cash flow period for its label links" do
    create_transaction(account: @family.accounts.first, amount: 100, category: categories(:food_and_drink), date: 3.days.ago.to_date)

    get root_path(cashflow_period: "custom", cashflow_start_date: 10.days.ago.to_date.iso8601, cashflow_end_date: Date.current.iso8601)

    assert_response :ok
    chart = css_select("#cashflowSankeyChart").sole
    assert_equal 10.days.ago.to_date.iso8601, chart["data-sankey-chart-start-date-value"]
    assert_equal Date.current.iso8601, chart["data-sankey-chart-end-date-value"]
    assert_select "#cashflowSankeyChart [data-sankey-chart-target='zoomOutButton'][hidden]"
  end

  test "outflow donut segments link with the category filter value" do
    create_transaction(account: @family.accounts.first, amount: 70, category: nil)

    get root_path

    assert_response :ok
    segments = JSON.parse(css_select("[data-controller='donut-chart']").first["data-donut-chart-segments-value"])
    uncategorized = segments.find { |segment| segment["name"] == Category.uncategorized_name }
    assert_equal Category::UNCATEGORIZED_FILTER_VALUE, uncategorized["filter_value"]
  end

  test "the subcategory toggle is off by default" do
    create_transaction(account: @family.accounts.first, amount: 100, category: categories(:food_and_drink))

    get root_path
    assert_response :ok
    assert_equal "false", css_select("#cashflowSankeyChart").sole["data-sankey-chart-show-subcategories-value"]
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

  test "the self-hosted user menu shows the build tag and no upstream links" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)

    get root_path

    assert_response :ok
    assert_select "[data-testid=build-tag]", text: Sure.build_tag
    assert_select "a[href*='we-promise']", count: 0
    assert_select "a[href*='discord.gg']", count: 0
  end

  # --- Exchange rate notes (w1-fx nearest-rate) ---

  test "dashboard warns about a currency with no exchange rate and notes a stale one" do
    family = @user.family
    family.accounts.create!(name: "PLN cash", balance: 100, currency: "PLN", accountable: Depository.new)
    family.accounts.create!(name: "EUR cash", balance: 100, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: family.currency, date: 30.days.ago.to_date, rate: 1.1)

    get root_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", text: /No exchange rate from PLN to #{family.currency}/
    assert_select "[data-testid=stale-exchange-rates]", text: /EUR from #{Regexp.escape(I18n.l(30.days.ago.to_date, format: :long))}/
  end

  test "dashboard shows no exchange rate note when every currency has a current rate" do
    get root_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", count: 0
    assert_select "[data-testid=stale-exchange-rates]", count: 0
  end
end
