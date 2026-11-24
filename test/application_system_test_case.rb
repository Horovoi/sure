require "test_helper"

# Capybara 3.40 (the latest) resets Chrome between tests with Storage.clearDataForOrigin for
# origin "*", which Chrome 158 rejects ("* is not a valid URL"), failing every system test in
# teardown. Clear the cookies of every origin and the app's own storage instead.
module ChromeResetForAnyOrigin
  private
    def execute_cdp(cmd, params = {})
      return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

      super("Network.clearBrowserCookies")
      app = Capybara.current_session.server&.base_url
      super(cmd, params.merge(origin: app)) if app && params[:storageTypes] != "cookies"
    end
end
require "capybara/selenium/driver"
require "capybara/selenium/driver_specializations/chrome_driver"
Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeResetForAnyOrigin)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  setup do
    # The dashboard after a login, or a save that syncs, can take longer than 5s on a busy
    # machine; a short wait made a different test fail in almost every full run
    Capybara.default_max_wait_time = 10
  end

  driven_by :selenium, using: ENV["CI"].present? ? :headless_chrome : ENV.fetch("E2E_BROWSER", :chrome).to_sym, screen_size: [ 1400, 1400 ]

  private

    def sign_in(user)
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "Email", with: user.email
        fill_in "Password", with: user_password_test
        click_on "Log in"
      end

      # Trigger Capybara's wait mechanism to avoid timing issues with logins
      find("h1", text: "Welcome back, #{user.first_name}")
    end

    def login_as(user)
      sign_in(user)
    end

    def sign_out
      within "div[data-testid=user-menu]" do
        find("button[aria-haspopup]").click
      end
      click_button I18n.t("users.user_menu.log_out")

      # Trigger Capybara's wait mechanism to avoid timing issues with logout
      find("a", text: "Sign in")
    end

    # Drags horizontally across the full width of `element` (a chart brush
    # overlay). Driven off the element's own rendered width, since chart widths
    # vary with viewport and font metrics; a start point outside the element
    # never begins the gesture.
    def drag_across(element, inset: 20)
      width = element.native.rect.width

      page.driver.browser.action
        .move_to(element.native, -(width / 2 - inset).round, 0)
        .click_and_hold
        .move_by((width - (2 * inset)).round, 0)
        .release
        .perform
    end

    def within_testid(testid)
      within "[data-testid='#{testid}']" do
        yield
      end
    end
end
