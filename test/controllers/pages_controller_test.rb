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

  # --- Hidden widgets and lazy builders (w2-dash dashboard-lazy-hide) ---

  test "a hidden Sankey section builds no payload" do
    @user.update!(preferences: { "hidden_sections" => { "cashflow_sankey" => true } })
    IncomeStatement::Sankey.expects(:new).never

    get root_path

    assert_response :ok
    assert_select "section[data-section-key='cashflow_sankey']", count: 0
    assert_select "#cashflow_sankey_dialog", count: 0
    assert_select "section[data-section-key='net_worth_chart']"
  end

  test "a widget's own frame request builds only that widget" do
    IncomeStatement::Sankey.expects(:new).never

    get root_path(outflows_period: "last_30_days"), headers: { "Turbo-Frame" => "outflows_donut_section" }

    assert_response :ok
  end

  test "customize mode hides a widget and redirects back with the view params" do
    patch dashboard_preferences_path, params: {
      customize: 1,
      cashflow_period: "last_90_days",
      preferences: { hidden_sections: { net_worth_chart: "true" } }
    }

    assert_redirected_to root_path(cashflow_period: "last_90_days", customize: 1, hidden_section: "net_worth_chart")
    assert @user.reload.dashboard_section_hidden?("net_worth_chart")

    follow_redirect!
    assert_select "section[data-section-key='net_worth_chart']", count: 0
    assert_select "[data-testid=dashboard-hidden-sections] button", text: /#{Regexp.escape(I18n.t("pages.dashboard.net_worth_chart.title"))}/
  end

  test "customize mode shows a hidden widget again" do
    @user.update!(preferences: { "hidden_sections" => { "net_worth_chart" => true } })

    patch dashboard_preferences_path, params: { customize: 1, preferences: { hidden_sections: { net_worth_chart: "false" } } }

    assert_redirected_to root_path(customize: 1, shown_section: "net_worth_chart")
    assert_not @user.reload.dashboard_section_hidden?("net_worth_chart")
    follow_redirect!
    assert_select "section[data-section-key='net_worth_chart'][autofocus]"
  end

  test "hidden flags are kept only for dashboard widgets" do
    patch dashboard_preferences_url, params: { preferences: { hidden_sections: { balance_sheet: true, not_a_widget: true } } }, as: :json

    assert_response :ok
    assert_equal({ "balance_sheet" => true }, @user.reload.preferences["hidden_sections"])
  end

  test "every widget hidden shows an empty state that links to customize mode" do
    hidden = PagesController::DASHBOARD_SECTION_KEYS.index_with(true)
    @user.update!(preferences: { "hidden_sections" => hidden })

    get root_path

    assert_response :ok
    assert_select "[data-dashboard-sortable-target=section]", count: 0
    assert_select "a[href=?]", root_path(customize: 1), text: I18n.t("pages.dashboard.customize.start")
  end

  test "customize mode puts a hide button on each widget" do
    get root_path(customize: 1)

    assert_response :ok
    assert_select "section[data-section-key='balance_sheet'] button[aria-label=?]",
      I18n.t("pages.dashboard.customize.hide", title: I18n.t("pages.dashboard.balance_sheet.title"))
    assert_select "[data-testid=dashboard-hidden-sections]", text: /#{Regexp.escape(I18n.t("pages.dashboard.customize.none_hidden"))}/
  end
end
