require "application_system_test_case"

class DashboardTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    # With the chat sidebar open the Sankey is narrower than its subcategory minimum
    # (SUBCATEGORY_MIN_WIDTH) at the test window size, and the toggle draws nothing
    @user.update!(show_ai_sidebar: false)
    @family = @user.family
    @start_date = Date.current.beginning_of_month
    @parent = @family.categories.create!(name: "Sankey Shopping", color: "#123456")
    @child = @family.categories.create!(name: "Sankey Groceries", parent: @parent)
    @account = @family.accounts.create!(name: "Sankey checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    create_transaction(account: @account, currency: @family.currency, category: @parent, amount: 100, date: @start_date)
    create_transaction(account: @account, currency: @family.currency, category: @child, amount: 50, date: @start_date)
    sign_in @user
  end

  test "the cash flow Sankey renders one payload with a deficit" do
    # More than any fixture income, so the period spends more than it earns
    rent = @family.categories.create!(name: "Sankey Rent", color: "#654321")
    create_transaction(account: @account, currency: @family.currency, category: rent, amount: 1_000_000, date: @start_date)

    visit_dashboard

    within "#cashflowSankeyChart" do
      assert_selector "svg .sankey-link"
      assert_selector "g[data-node-id='cash_flow_node']"
      assert_selector "g[data-node-id='expense_#{@parent.id}']"
      assert_selector "g[data-node-kind='deficit']"
    end

    # A hidden label must not catch the clicks of the bar it sits over
    assert page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#cashflowSankeyChart svg text"))
        .filter(text => text.style.opacity === "0")
        .every(text => getComputedStyle(text).pointerEvents === "none")
    JS
  end

  test "the subcategory toggle adds the subcategory column without a request" do
    visit_dashboard

    within "#cashflowSankeyChart" do
      assert_selector "g[data-node-id='expense_#{@parent.id}']"
      assert_no_selector "g[data-node-id='expense_sub_#{@child.id}']"
    end

    page.execute_script("window.__sankeyMarker = true")
    find("label[for='cashflow_show_subcategories']", text: I18n.t("pages.dashboard.cashflow_sankey.show_subcategories")).click

    within "#cashflowSankeyChart" do
      assert_selector "g[data-node-id='expense_sub_#{@child.id}']"
      assert_selector "g[data-node-id='expense_sub_#{@parent.id}_other']"
    end
    assert page.evaluate_script("window.__sankeyMarker === true"), "the toggle must not reload the page"
  end

  test "the fullscreen dialog draws the chart and shares the subcategory toggle" do
    visit_dashboard

    within "#cashflow-sankey-chart" do
      click_button I18n.t("pages.dashboard.cashflow_sankey.expand"), enable_aria_label: true
    end

    within "#cashflow_sankey_dialog" do
      assert_selector "#cashflowSankeyChartFullscreen svg .sankey-link"
      assert_no_selector "#cashflowSankeyChartFullscreen g[data-node-id='expense_sub_#{@child.id}']"

      find("label[for='cashflow_show_subcategories_dialog']", text: I18n.t("pages.dashboard.cashflow_sankey.show_subcategories")).click

      assert_selector "#cashflowSankeyChartFullscreen g[data-node-id='expense_sub_#{@child.id}']"
    end

    assert find("#cashflow_show_subcategories", visible: :all).checked?
    assert_selector "#cashflowSankeyChart g[data-node-id='expense_sub_#{@child.id}']", visible: :all
  end

  test "a category label opens its transactions for the widget period" do
    make_shopping_prominent
    visit_dashboard

    find("#cashflowSankeyChart g[data-node-id='expense_#{@parent.id}'] text").click

    assert_current_path(%r{/transactions\?})
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    assert_equal [ @parent.filter_value ], query.dig("q", "categories")
    assert_equal @start_date.iso8601, query.dig("q", "start_date")
    assert_equal Date.current.iso8601, query.dig("q", "end_date")
  end

  test "the Cash Flow label zooms to the spending side instead of opening transactions" do
    make_shopping_prominent
    visit_dashboard

    nodes = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#cashflowSankeyChart g[data-node-id]")).map(g => g.__data__)
        .filter(d => ["cash_flow_node", "deficit_node", "surplus_node"].includes(d.id))
        .map(d => d.filter_value ?? null)
    JS
    # The values are all nil, so not nodes.any?
    assert_not_empty nodes
    assert nodes.all?(&:nil?), "structural nodes have no transactions filter"

    find("#cashflowSankeyChart g[data-node-id='cash_flow_node'] text").click

    assert_selector "#cashflowSankeyChart [data-sankey-chart-target='zoomOutButton']"
    assert_current_path(root_path, ignore_query: true)
  end

  test "zoom into a category and back in the inline chart" do
    make_shopping_prominent
    visit_dashboard

    within "#cashflowSankeyChart" do
      assert_no_selector "g[data-node-id='expense_sub_#{@child.id}']"
      assert_no_selector "[data-sankey-chart-target='zoomOutButton']", visible: true

      find("g[data-node-id='expense_#{@parent.id}'] path").click

      assert_selector "g[data-node-id='expense_sub_#{@child.id}']"
      assert_no_selector "g[data-node-id='cash_flow_node']"

      find("[data-sankey-chart-target='zoomOutButton']").click

      assert_selector "g[data-node-id='cash_flow_node']"
      assert_no_selector "[data-sankey-chart-target='zoomOutButton']", visible: true
    end
  end

  test "zoom into a category and back in the fullscreen dialog" do
    make_shopping_prominent
    visit_dashboard

    within "#cashflow-sankey-chart" do
      click_button I18n.t("pages.dashboard.cashflow_sankey.expand"), enable_aria_label: true
    end

    within "#cashflowSankeyChartFullscreen" do
      assert_selector "svg .sankey-link"
      find("g[data-node-id='expense_#{@parent.id}'] path").click

      assert_selector "g[data-node-id='expense_sub_#{@child.id}']"
      assert_no_selector "g[data-node-id='cash_flow_node']"

      click_button I18n.t("pages.dashboard.cashflow_sankey.zoom_out"), enable_aria_label: true

      assert_selector "g[data-node-id='cash_flow_node']"
    end

    # The inline chart behind keeps its own, full view
    assert_selector "#cashflowSankeyChart g[data-node-id='cash_flow_node']", visible: :all
  end

  test "hide a widget in customize mode, it stays hidden after a reload, then show it again" do
    net_worth = I18n.t("pages.dashboard.net_worth_chart.title")
    visit root_path
    click_link I18n.t("pages.dashboard.customize.start"), match: :first

    click_button I18n.t("pages.dashboard.customize.hide", title: net_worth), enable_aria_label: true
    assert_no_selector "section[data-section-key='net_worth_chart']"
    assert_selector "[data-testid=dashboard-hidden-sections]", text: net_worth

    visit root_path
    assert_selector "section[data-section-key='balance_sheet']"
    assert_no_selector "section[data-section-key='net_worth_chart']"

    click_link I18n.t("pages.dashboard.customize.start"), match: :first
    within "[data-testid=dashboard-hidden-sections]" do
      click_button net_worth
    end
    assert_selector "section[data-section-key='net_worth_chart']"

    click_link I18n.t("pages.dashboard.customize.done")
    assert_no_button I18n.t("pages.dashboard.customize.hide", title: net_worth), enable_aria_label: true
    assert_selector "section[data-section-key='net_worth_chart']"
  end

  # Both periods are compared by day of period, so the two rows carry different calendar
  # dates; the header names the day they share and each row starts with its period.
  test "the spending tooltip names the day of period above both periods" do
    visit root_path
    current_label = nil
    within "#spending-trend-section" do
      chart = find("[data-controller='spending-chart']")
      current_label = chart["data-spending-chart-current-label-value"]
      chart.find("svg path[data-series='current']").hover
    end

    tooltip = find(".chart-tooltip", visible: true)
    # Low on the screen it opens above the cursor, so all of it stays in view
    rect = page.evaluate_script("(() => { const r = document.querySelector('.chart-tooltip').getBoundingClientRect(); return [r.top, r.bottom, window.innerHeight]; })()")
    assert rect[0] >= 0 && rect[1] <= rect[2], "tooltip runs off screen: #{rect.inspect}"
    assert_match(/\ADay \d+\z/, tooltip.find("[data-testid='spending-tooltip-day']").text)
    # Each row reads period, date, amount
    assert_match(/\ADay \d+\s+#{Regexp.escape(current_label)}\s/, tooltip.text)
  end

  test "the spending category filter changes the curve" do
    travel = @family.categories.create!(name: "Curve Travel", color: "#2244aa")
    create_transaction(account: @account, currency: @family.currency, category: travel, amount: 700_000, date: @start_date)

    visit root_path
    total = nil
    within "#spending-trend-section" do
      assert_selector "[data-controller='spending-chart'] svg path[data-series='current']"
      total = find("[data-testid='spending-trend-current-total']").text

      click_button I18n.t("pages.dashboard.spending_trend.filter_categories_all")
      find("label[data-filter-name='Curve Travel'] input[type='checkbox']").click
      # Unchecking a subcategory unchecks its parent, so the parent no longer covers it
      find("label[data-filter-name='#{@child.name}'] input[type='checkbox']").click
      assert_not find("label[data-filter-name='#{@parent.name}'] input[type='checkbox']").checked?
      click_button I18n.t("pages.dashboard.spending_trend.apply")
    end

    within "#spending-trend-section" do
      assert_no_selector "[data-testid='spending-trend-current-total']", exact_text: total
      assert_not find("label[data-filter-name='Curve Travel'] input[type='checkbox']", visible: :all).checked?
    end
  end

  test "the spending fullscreen dialog keeps its period picker and category filter working" do
    travel = @family.categories.create!(name: "Curve Travel", color: "#2244aa")
    create_transaction(account: @account, currency: @family.currency, category: travel, amount: 700_000, date: @start_date)

    visit root_path
    within "#spending-trend-section" do
      assert_selector "[data-controller='spending-chart'] svg path[data-series='current']"
      click_button I18n.t("pages.dashboard.spending_trend.expand"), enable_aria_label: true
    end

    # The dialog itself takes the focus, not its close button (Safari rings that one)
    assert_equal "spending_trend_fullscreen_dialog", page.evaluate_script("document.activeElement.id")

    total = nil
    within "#spending_trend_fullscreen_dialog" do
      assert_selector "#spending-trend-fullscreen-section [data-controller='spending-chart'] svg path[data-series='current']"
      total = find("[data-testid='spending-trend-current-total']").text

      click_button I18n.t("pages.dashboard.spending_trend.filter_categories_all")
      find("label[data-filter-name='Curve Travel'] input[type='checkbox']").click
      click_button I18n.t("pages.dashboard.spending_trend.apply")

      # The dialog stays open, and its frame shows the narrowed curve
      assert_no_selector "[data-testid='spending-trend-current-total']", exact_text: total
      assert_selector "[data-controller='spending-chart'] svg path[data-series='current']"
    end
    narrowed = find("#spending_trend_fullscreen_dialog [data-testid='spending-trend-current-total']").text

    # The inline widget behind the dialog follows to the same filter
    assert_selector "#spending-trend-section [data-testid='spending-trend-current-total']", exact_text: narrowed, visible: :all

    # The period picker inside the dialog loads the previous period, still in the dialog
    previous_start = @family.budget_period_start_for(@family.budget_period_start_for(Date.current) - 1)
    previous_label = I18n.l(previous_start, format: I18n.t("pages.dashboard.spending_trend.period_format"))
    within "#spending_trend_fullscreen_dialog" do
      select previous_label, from: "spending_period_fullscreen"
      assert_selector "select#spending_period_fullscreen option[selected]", text: previous_label, visible: :all
      assert_selector "#spendingFullscreenPeriod", text: I18n.l(previous_start, format: :long)
    end
    assert_selector "#spending_trend_fullscreen_dialog[open]"
    assert_selector "#spending-trend-section select#spending_period option[selected]", text: previous_label, visible: :all
  end

  # --- w2-netw ---

  test "a drag across the net worth chart selects that date range" do
    original_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }

    # Scrolled down to the chart, as a user is when they drag across it
    page.execute_script("document.getElementById('netWorthChart').scrollIntoView({ block: 'center' })")
    scroll_before = page.evaluate_script("document.querySelector('main').scrollTop")
    assert_operator scroll_before, :>, 0

    # The chart sits in a draggable dashboard section. The gesture must reach
    # the chart's brush, not the section's drag-and-drop reordering.
    drag_across find("#netWorthChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(/net_worth_period=custom/)

    # The range loads into the widget's frame: the dashboard stays where it was
    # instead of reloading at the top
    assert_selector "#netWorthChart .drag-select-brush .overlay", visible: :all
    assert_in_delta scroll_before, page.evaluate_script("document.querySelector('main').scrollTop"), 40
    query = Rack::Utils.parse_query(URI.parse(current_url).query)
    start_date = Date.parse(query.fetch("net_worth_start_date"))
    end_date = Date.parse(query.fetch("net_worth_end_date"))
    assert_operator start_date, :<, end_date

    # The chart redraws for the range, with its brush again, and the custom
    # date fields show the range
    assert_selector "#netWorthChart svg"
    assert_selector "#netWorthChart .drag-select-brush .overlay", visible: :all
    assert_field "net_worth_start_date", with: start_date.iso8601
    assert_field "net_worth_end_date", with: end_date.iso8601

    # Dashboard sections kept their order. Sections that have no data for the
    # range may hide, so only the common ones are compared.
    new_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }
    common_keys = original_order & new_order
    assert_equal common_keys, new_order & common_keys

    # The fullscreen dialog shows the same range
    find("[data-fullscreen-target-id-value='net_worth_fullscreen_dialog']").click
    within "#net_worth_fullscreen_dialog" do
      assert_selector "#netWorthFullscreenPeriod", text: I18n.l(start_date, format: "%b %d, %Y")
      assert_selector "#netWorthFullscreenPeriod", text: I18n.l(end_date, format: "%b %d, %Y")
      assert_selector "#netWorthChartFullscreen svg"
    end
  end

  test "a click on the net worth chart does not change the period" do
    overlay = find("#netWorthChart .drag-select-brush .overlay", visible: :all)
    overlay.click

    assert_no_current_path(/net_worth_period=custom/)
  end

  # --- w3-reports exclude-from-reports ---

  test "excluding an account from the account menu takes it out of the dashboard totals" do
    savings = @family.accounts.create!(name: "Excluded savings", currency: @family.currency, balance: 123_456, accountable: Depository.new)
    with_savings = BalanceSheet.new(@family).assets.total_money.format(precision: 0)

    visit root_path
    within("#balance-sheet") { assert_text with_savings }

    visit account_path(savings)
    within_testid("account-menu") do
      find("button").click
      click_on I18n.t("accounts.exclude_from_reports.menu_exclude")
    end
    # Waits for the saved state, not the flash: the flash fades after a few seconds and a
    # busy machine can miss it
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, "account not excluded yet" unless savings.reload.exclude_from_reports?
    end

    without_savings = BalanceSheet.new(@family.reload).assets.total_money.format(precision: 0)
    assert_not_equal with_savings, without_savings

    visit root_path
    within("#balance-sheet") do
      assert_text without_savings
      assert_no_text with_savings
    end
  end

  private
    # Large enough that the chart's label rule keeps the Shopping label
    def make_shopping_prominent
      create_transaction(account: @account, currency: @family.currency, category: @child, amount: 500_000, date: @start_date)
    end

    def visit_dashboard
      visit root_path(cashflow_period: "custom", cashflow_start_date: @start_date.iso8601, cashflow_end_date: Date.current.iso8601)
      assert_selector "#cashflowSankeyChart svg .sankey-link"
    end
end
