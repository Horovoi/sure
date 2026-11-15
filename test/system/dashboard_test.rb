require "application_system_test_case"

class DashboardTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "a drag across the net worth chart selects that date range" do
    original_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }

    # The chart sits in a draggable dashboard section. The gesture must reach
    # the chart's brush, not the section's drag-and-drop reordering.
    drag_across find("#netWorthChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(/net_worth_period=custom/)
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
end
