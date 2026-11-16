require "application_system_test_case"

# Privacy mode: the eye toggle (and Shift+H) blurs every .privacy-sensitive
# amount. The state lives in localStorage and the class sits on <html>, so it
# survives Turbo visits and full page loads.
class PrivacyModeTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "the toggle blurs amounts across visits and reloads, and Shift+H turns it off" do
    visit root_path
    assert_not privacy_mode?

    wait_for_page_scripts
    toggle.click
    assert_selector "html.privacy-mode", visible: :all
    assert_equal "true", toggle["aria-pressed"]
    assert_match "blur", page.evaluate_script("getComputedStyle(document.querySelector('.privacy-sensitive')).filter")

    # A Turbo visit keeps <html>, and the new page's toggle gets the state
    find("a[href='#{transactions_path}']", match: :first).click
    assert_selector "h1", text: "Transactions"
    assert privacy_mode?
    assert_equal "true", toggle["aria-pressed"]

    # A full load sets the class from localStorage before the page paints
    visit budgets_path
    assert privacy_mode?

    # The inline head script sets the class before the page's JS starts; a key sent
    # before the hotkey is installed is lost
    wait_for_page_scripts
    press_shift_h
    assert_no_selector "html.privacy-mode", visible: :all
    assert_equal "false", toggle["aria-pressed"]

    visit root_path
    assert_not privacy_mode?
  end

  # WebKit (Safari) ignores CSS blur() on SVG, so chart labels drawn by D3 use the
  # SVG filter every engine applies, on <text> and <tspan> alike
  test "chart amounts drawn as SVG use the SVG blur filter" do
    visit root_path
    page.execute_script("localStorage.setItem('privacyMode', 'true')")
    visit root_path
    assert_selector "svg .privacy-sensitive", visible: :all, minimum: 1
    assert_selector "filter#privacy-blur feGaussianBlur", visible: :all

    filters = evaluate_script("[...document.querySelectorAll('svg .privacy-sensitive')].map((el) => getComputedStyle(el).filter)")
    assert filters.all? { |filter| filter.include?("#privacy-blur") }, filters.uniq.inspect
  end

  test "a blurred money field stays usable" do
    page.execute_script("localStorage.setItem('privacyMode', 'true')")
    visit new_transaction_path

    field = find("input[name='entry[amount]']")
    assert_includes field[:class], "privacy-sensitive"
    field.fill_in with: "12.50"
    assert_equal "12.50", field.value
  end

  private
    # Through the Actions API: an element's send_keys turns a letter into a key event
    # through the machine's keyboard layout, so with a non-Latin layout active (Ukrainian)
    # Chrome gets a keydown with an empty key and no hotkey fires.
    def press_shift_h
      page.driver.browser.action.key_down(:shift).send_keys("h").key_up(:shift).perform
    end

    # The page's Stimulus controllers are connected: the toggle shows the stored state
    # and the Shift+H hotkey is installed.
    def wait_for_page_scripts
      assert_selector "[data-testid='privacy-toggle'][aria-pressed='#{privacy_mode?}']"
      page.document.synchronize do
        installed = page.evaluate_script(<<~JS)
          !!window.Stimulus?.getControllerForElementAndIdentifier(document.querySelector("[data-hotkey='Shift+H']"), "hotkey")?.installed
        JS
        raise Capybara::ExpectationNotMet, "the Shift+H hotkey is not installed yet" unless installed
      end
    end

    def toggle
      find("[data-testid='privacy-toggle']", visible: true)
    end

    def privacy_mode?
      page.has_css?("html.privacy-mode", visible: :all, wait: 0)
    end
end
