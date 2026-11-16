require "application_system_test_case"

# Resizable side panels, expand / collapse all account groups, and the skip link
class LayoutExtrasTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(show_sidebar: true, show_ai_sidebar: true)
    sign_in @user
  end

  test "the accounts panel resizes from the keyboard, keeps its width and resets" do
    visit root_path
    handle = left_handle

    assert_equal "320", handle["aria-valuenow"]
    handle.send_keys(:right, :right)
    assert_panel_width "app_left_panel", 352
    assert_equal "352", left_handle["aria-valuenow"]

    # The width is remembered across pages
    visit transactions_path
    assert_panel_width "app_left_panel", 352

    left_handle.send_keys(:home)
    assert_panel_width "app_left_panel", 320
  end

  test "dragging the assistant divider resizes it and a double-click resets it" do
    visit root_path
    handle = find("[role=separator][aria-label='#{I18n.t("layouts.application.resize_right_sidebar")}']")

    # The right panel grows as its left edge moves left
    page.driver.browser.action.drag_and_drop_by(handle.native, -60, 0).perform
    assert_panel_width "app_right_panel", 460, within: 4

    handle.double_click
    assert_panel_width "app_right_panel", 400
  end

  test "the main column keeps room however wide the panels are dragged" do
    visit root_path
    handle = left_handle
    20.times { handle.send_keys(:right) }

    main = evaluate_script("document.getElementById('main-content').getBoundingClientRect().width")
    assert_operator main, :>=, 480
  end

  test "expand all opens every account group, remembered across pages, and collapses them again" do
    visit root_path
    within "#app_left_panel" do
      toggle = find("button[aria-label='#{I18n.t("shared.expand_all_toggle.expand_all")}']", match: :first)
      assert_equal "false", toggle["aria-expanded"]
      toggle.click

      # Only the visible tab's groups are judged
      panel = find("[data-controller=disclosure-group]", match: :first)
      assert_no_selector_in panel, "details[data-disclosure-group-key]:not([open])"
      assert_selector "button[aria-label='#{I18n.t("shared.expand_all_toggle.collapse_all")}'][aria-expanded=true]", match: :first
    end

    visit transactions_path
    within "#app_left_panel" do
      panel = find("[data-controller=disclosure-group]", match: :first)
      assert_no_selector_in panel, "details[data-disclosure-group-key]:not([open])"

      panel.find("button[aria-label='#{I18n.t("shared.expand_all_toggle.collapse_all")}']").click
      assert_no_selector_in panel, "details[data-disclosure-group-key][open]"
    end
  end

  test "the dashboard balance sheet expands and collapses all of its groups" do
    visit root_path
    within "#balance-sheet" do
      section = find("[data-controller=disclosure-group]", match: :first)
      section.find("button[aria-label='#{I18n.t("shared.expand_all_toggle.expand_all")}']").click
      assert_no_selector_in section, "details[data-disclosure-group-key]:not([open])"
    end
  end

  test "the first Tab reaches a skip link that moves focus to the page" do
    visit root_path
    find("body").send_keys(:tab)
    link = find("a[href='#main-content']", text: I18n.t("layouts.application.skip_to_content"))
    assert_equal link.native, page.driver.browser.switch_to.active_element

    link.send_keys(:enter)
    assert_equal "main-content", evaluate_script("document.activeElement.id")
  end

  private
    def left_handle
      find("[role=separator][aria-label='#{I18n.t("layouts.application.resize_left_sidebar")}']")
    end

    # Waits like Capybara does: the groups open or close as toggle events land
    def assert_no_selector_in(scope, css)
      scope.assert_no_selector(css, visible: :all)
    end

    def assert_panel_width(id, expected, within: 1)
      width = nil
      assert(
        5.times.any? do
          width = evaluate_script("document.getElementById('#{id}').getBoundingClientRect().width")
          (width - expected).abs <= within || (sleep(0.4) && false)
        end,
        "#{id} is #{width}px wide, expected #{expected}"
      )
    end
end
