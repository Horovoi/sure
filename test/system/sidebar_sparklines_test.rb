require "application_system_test_case"

# The sidebar sparkline containers are tiny: 32x12 for an account group total
# and 32x20 for an account row. The time-series chart controller used to skip
# any container under 50x50, so a frame could load and still stay blank. The
# trendline is the only <path> the controller draws at these sizes (the empty
# state draws a dashed <line> and a <circle>), so a <path> proves a real series
# was drawn, not just an empty <svg>.
class SidebarSparklinesTest < ApplicationSystemTestCase
  SIDEBAR = "[data-app-layout-target='leftSidebar']"
  SPARKLINE_FRAME = "#{SIDEBAR} turbo-frame[data-controller='turbo-frame-timeout']"

  # Rows are `dom_id(account, :sparkline)`; the group total is
  # "#{account_group.key}_sparkline".
  ACCOUNT_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}[id^='sparkline_account_']"
  GROUP_SPARKLINE_FRAME = "#{SPARKLINE_FRAME}[id$='_sparkline']:not([id^='sparkline_account_'])"

  setup do
    sign_in users(:family_admin)
  end

  test "the group total sparkline draws its chart, not just its frame" do
    visit root_path

    assert_selector "#{GROUP_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart'] svg path", minimum: 1
  end

  test "expanding a group draws the account sparklines, not just their frames" do
    visit root_path

    # The first account group, not the "missing data provider" notice, which
    # is also a <details> in the sidebar.
    find("#{SIDEBAR} details:has(turbo-frame[id$='_sparkline'])", match: :first).find("summary", match: :first).click

    assert_selector "#{ACCOUNT_SPARKLINE_FRAME}[complete] [data-controller='time-series-chart'] svg path", minimum: 1
  end
end
