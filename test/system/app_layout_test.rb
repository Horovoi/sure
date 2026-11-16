require "application_system_test_case"

# The side panels and the phone drawer of the app layout
class AppLayoutTest < ApplicationSystemTestCase
  LEFT = "#app_left_panel"
  RIGHT = "#app_right_panel"

  setup do
    @user = users(:family_admin)
    @user.update!(show_sidebar: true, show_ai_sidebar: true)
    sign_in @user
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "a window too narrow for both panels shows the accounts panel and keeps the main column usable" do
    page.driver.browser.manage.window.resize_to(1100, 900)
    visit reports_path

    assert_panel_shown LEFT
    assert_panel_hidden RIGHT
    assert_toggle_state "app_left_panel", "true"
    assert_toggle_state "app_right_panel", "false"
    assert_operator main_width, :>=, 600

    # Opening the assistant makes room for it by closing the accounts panel
    find("button[aria-controls=app_right_panel]").click

    assert_panel_shown RIGHT
    assert_panel_hidden LEFT
    assert_toggle_state "app_left_panel", "false"
    assert_toggle_state "app_right_panel", "true"
    assert_operator main_width, :>=, 500
    wait_for { !@user.reload.show_sidebar }
    assert @user.show_ai_sidebar
  end

  test "a wide window shows both panels and the toggles report it" do
    visit root_path

    assert_panel_shown LEFT
    assert_panel_shown RIGHT
    assert_toggle_state "app_left_panel", "true"
    assert_toggle_state "app_right_panel", "true"

    find("button[aria-controls=app_left_panel]").click

    assert_panel_hidden LEFT
    assert_toggle_state "app_left_panel", "false"
    assert_panel_shown RIGHT
  end

  test "the phone accounts drawer is a modal dialog that Escape closes" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit reports_path

    opener = find("button[aria-controls=app_mobile_sidebar]")
    assert_equal "false", opener["aria-expanded"]
    opener.click

    assert_selector "dialog#app_mobile_sidebar[open]"
    assert_selector "button[aria-controls=app_mobile_sidebar][aria-expanded=true]"
    # Focus is on the drawer itself, not its close button: Safari rings a button that
    # takes the focus as a dialog opens
    assert_equal "app_mobile_sidebar", page.evaluate_script("document.activeElement.id")

    page.driver.browser.action.send_keys(:escape).perform

    assert_no_selector "dialog#app_mobile_sidebar[open]"
    assert_selector "button[aria-controls=app_mobile_sidebar][aria-expanded=false]"
  end

  test "a closed assistant panel loads its chat only when opened" do
    @user.update!(show_ai_sidebar: false)
    visit reports_path

    frame = "#app_right_panel turbo-frame#sidebar_chat"
    assert_selector "#{frame}:not([src])", visible: :all

    find("button[aria-controls=app_right_panel]").click

    assert_selector "#{frame}[src]", visible: :all
    assert_panel_shown RIGHT
  end

  test "the chats page has no assistant panel beside it" do
    visit chats_path

    assert_no_selector RIGHT, visible: :all
    assert_no_selector "button[aria-controls=app_right_panel]"

    # The accounts panel still opens and closes
    find("button[aria-controls=app_left_panel]").click
    assert_panel_hidden LEFT
  end

  test "the logo link has a name" do
    visit root_path

    assert_selector "a[href='/'][aria-label='#{I18n.t("layouts.application.home")}']", minimum: 1
  end

  private
    def panel_width(selector)
      page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().width")
    end

    def main_width
      page.evaluate_script("document.querySelector('main').getBoundingClientRect().width")
    end

    # The panels slide open and closed (a 300ms transition)
    def assert_panel_shown(selector)
      wait_for { panel_width(selector) > 200 }
      assert_not page.evaluate_script("document.querySelector('#{selector}').inert"), "#{selector} is inert while shown"
    end

    def assert_panel_hidden(selector)
      wait_for { panel_width(selector) < 1 }
      assert page.evaluate_script("document.querySelector('#{selector}').inert"), "#{selector} is not inert while hidden"
    end

    def assert_toggle_state(controls, expanded)
      assert_selector "button[aria-controls=#{controls}][aria-expanded=#{expanded}]"
    end

    def wait_for(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until yield
        raise Minitest::Assertion, "condition not met within #{timeout}s" if Time.current > deadline

        sleep 0.05
      end
    end
end
