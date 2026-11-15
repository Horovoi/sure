require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "the arrows step through periods and Current goes back" do
    visit reports_path(period_type: :monthly)
    current_label = find("[data-testid='report-period-label']").text
    assert_selector "button[disabled][aria-label='#{I18n.t("reports.index.period_nav.next")}']"

    find("a[aria-keyshortcuts='ArrowLeft']").click
    assert_current_path(/period_offset=-1/)
    assert_no_selector "[data-testid='report-period-label']", text: current_label, exact_text: true

    find("a[aria-keyshortcuts='ArrowRight']").click
    assert_no_current_path(/period_offset/)
    assert_selector "[data-testid='report-period-label']", text: current_label, exact_text: true

    find("a[aria-keyshortcuts='ArrowLeft']").click
    find("a[aria-keyshortcuts='ArrowLeft']").click
    assert_current_path(/period_offset=-2/)
    within("[data-testid='report-period-nav']") { click_link I18n.t("reports.index.period_nav.current") }
    assert_no_current_path(/period_offset/)
    assert_selector "[data-testid='report-period-label']", text: current_label, exact_text: true
  end

  test "the left and right arrow keys change the period" do
    visit reports_path(period_type: :quarterly)
    wait_for_hotkeys

    page.send_keys(:arrow_left)
    assert_current_path(/period_offset=-1/)
    wait_for_hotkeys

    page.send_keys(:arrow_left)
    assert_current_path(/period_offset=-2/)
    wait_for_hotkeys

    page.send_keys(:arrow_right)
    assert_current_path(/period_offset=-1/)
  end

  test "the arrow keys leave section moves and dialogs alone" do
    visit reports_path(period_type: :monthly)
    wait_for_hotkeys
    record_hotkey_clicks

    find("section[data-section-key]", match: :first).send_keys(:enter)
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys
    page.send_keys(:escape)

    click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    assert_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a held arrow key steps one period" do
    visit reports_path(period_type: :monthly)
    wait_for_hotkeys
    record_hotkey_clicks

    page.execute_script(<<~JS)
      for (const repeat of [false, true, true]) {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", repeat, bubbles: true }));
      }
    JS

    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  private
    # The tooltip only shows once the page's controllers are connected, so
    # keys pressed after this reach an installed hotkey.
    def wait_for_hotkeys
      find("a[aria-keyshortcuts='ArrowLeft']").hover
      assert_selector "[role='tooltip']", text: "Previous period (←)"
      # Move the pointer away so the tooltip does not cover the page
      find("h1").hover
    end

    # Records the links the hotkeys click instead of following them. A hotkey
    # clicks synchronously, so the list is complete when the key returns.
    def record_hotkey_clicks
      page.execute_script(<<~JS)
        window.clickedHotkeys = [];
        document.addEventListener("click", (event) => {
          const link = event.target.closest("a[data-hotkey]");
          if (!link) return;
          window.clickedHotkeys.push(link.dataset.hotkey);
          event.preventDefault();
        }, true);
      JS
    end

    def clicked_hotkeys
      page.evaluate_script("window.clickedHotkeys")
    end
end
