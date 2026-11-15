require "application_system_test_case"

# The time-series chart bakes theme-dependent colors into SVG attributes (the
# endpoint marker outline, tick and guide opacities), which a CSS variable
# change cannot reach. theme_controller dispatches `theme:change` and the chart
# redraws itself on it.
class ChartThemeRepaintTest < ApplicationSystemTestCase
  CHART = "#netWorthChart[data-controller='time-series-chart']"
  LIGHT_OUTLINE = "var(--color-white)"
  DARK_OUTLINE = "var(--color-gray-900)"

  setup do
    @user = users(:family_admin)
    @user.update!(theme: "light")
    sign_in @user
  end

  test "switching the theme redraws the dashboard net worth chart" do
    visit root_path

    assert_selector "html[data-theme='light']"
    assert_selector "#{CHART} svg"

    markers_before = outline_strokes
    # Tag the current drawing; a redraw replaces the <svg>, so the tag goes.
    page.execute_script("document.querySelector(#{"#{CHART} svg".to_json}).dataset.drawnBefore = 'true'")

    switch_theme(dark: true)

    assert_selector "html[data-theme='dark']"
    assert_selector "#{CHART} svg"
    assert_no_selector "#{CHART} svg[data-drawn-before]"
    # The redraw keeps the drag-to-select brush
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all

    # The endpoint markers only appear when the series is not flat; when they
    # are there, their outline must follow the theme.
    if markers_before.any?
      assert_equal [ LIGHT_OUTLINE ], markers_before.uniq
      assert_equal [ DARK_OUTLINE ], outline_strokes.uniq
    end
  end

  private

    def switch_theme(dark:)
      page.execute_script(<<~JS)
        window.Stimulus
          .getControllerForElementAndIdentifier(document.documentElement, "theme")
          .setTheme(#{dark})
      JS
    end

    # The inner endpoint dots are the markers that carry a stroke.
    def outline_strokes
      all("#{CHART} circle.endpoint-marker[stroke]", wait: 0).map { |circle| circle[:stroke] }
    end
end
