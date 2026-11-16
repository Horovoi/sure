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

    find("body").send_keys([ :shift, "h" ])
    assert_no_selector "html.privacy-mode", visible: :all
    assert_equal "false", toggle["aria-pressed"]

    visit root_path
    assert_not privacy_mode?
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
    def toggle
      find("[data-testid='privacy-toggle']", visible: true)
    end

    def privacy_mode?
      page.has_css?("html.privacy-mode", visible: :all, wait: 0)
    end
end
