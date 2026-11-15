require "application_system_test_case"

class DashboardTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
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

  private
    def visit_dashboard
      visit root_path(cashflow_period: "custom", cashflow_start_date: @start_date.iso8601, cashflow_end_date: Date.current.iso8601)
      assert_selector "#cashflowSankeyChart svg .sankey-link"
    end
end
