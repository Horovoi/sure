require "application_system_test_case"

# Turbo caches a page as it was left, and Back restores that copy. A drawer or
# modal fetched into the page came back with it: stray and non-modal if it was
# still open, opened again if it had been closed.
class DialogBackTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @transfer = transfers(:one)
    @row_link = "a[data-turbo-frame='drawer'][href='#{transfer_path(@transfer)}']"
    @account = accounts(:depository)
  end

  test "going back from an account the transfer drawer linked to shows the list without the drawer" do
    visit transactions_url
    open_transfer_drawer
    within("dialog[open]") { click_on @account.name }
    assert_selector "main h2", text: @account.name

    page.go_back
    assert_selector "main h1", text: "Transactions"
    assert_no_selector "dialog[open]"
  end

  test "a drawer closed before leaving the list stays closed on Back" do
    visit transactions_url
    open_transfer_drawer
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"

    leave_the_list_and_come_back
    assert_no_selector "dialog[open]"
  end

  # The modal frame is emptied as its dialog closes, however it closes. Escape
  # closes it natively, without the controller's close.
  test "a modal closed with Escape before leaving the list stays closed on Back" do
    visit transactions_url
    click_on "New transaction", match: :first
    assert_selector "turbo-frame#modal dialog[open]"
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"

    leave_the_list_and_come_back
    assert_no_selector "dialog[open]"
  end

  # Visited directly, the drawer is the page, so Back has to bring it back.
  test "going back to a drawer visited directly restores it as a modal" do
    visit transfer_url(@transfer)
    within("dialog[open]") { click_on @account.name }
    assert_selector "main h2", text: @account.name

    page.go_back
    within("dialog:modal") { assert_link @account.name }
  end

  # Escape closes a dialog natively. A reload-on-close dialog routes it through
  # its own close, so Escape reloads the page like the close button does.
  test "Escape on a reload-on-close dialog reloads the page" do
    visit confirm_rule_url(rules(:one), reload_on_close: true)
    assert_selector "dialog:modal"

    # Only the page as it was before the reload carries this mark.
    execute_script("document.body.dataset.left = ''")
    page.send_keys(:escape)

    assert_no_selector "body[data-left]"
  end

  test "Tab stays inside an open modal and focus returns to the opener on close" do
    visit transactions_url
    opener = find("a[href='#{new_transaction_path}']", match: :first)
    opener.click
    assert_selector "turbo-frame#modal dialog:modal"

    12.times do
      page.send_keys(:tab)
      assert evaluate_script("document.querySelector('dialog:modal').contains(document.activeElement)"),
        "Focus left the modal"
    end
    page.send_keys([ :shift, :tab ])
    assert evaluate_script("document.querySelector('dialog:modal').contains(document.activeElement)")

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_equal new_transaction_path, evaluate_script("document.activeElement.getAttribute('href')")
  end

  test "the transactions filter popover closes after Apply" do
    visit transactions_url
    find("#transaction-filters-button").click
    assert_selector "#transaction-filters-menu"

    within "#transaction-filters-menu" do
      check @account.name
      click_button "Apply"
    end

    within "#transaction-search-filters" do
      assert_text @account.name
    end
    assert_no_selector "#transaction-filters-menu"
  end

  test "the user menu is a popover, not an action menu" do
    visit root_url

    within "div[data-testid=user-menu]", match: :first do
      trigger = find("button[aria-haspopup='dialog']")
      assert_equal "false", trigger[:'aria-expanded']
      trigger.click
      assert_equal "true", trigger[:'aria-expanded']
    end

    assert_no_selector "[role='menu']", text: I18n.t("users.user_menu.log_out")
    assert_button I18n.t("users.user_menu.log_out")
  end

  private
    # The row's name can be cut to nothing beside its badges, so this clicks the
    # link the way the row's own click handler does.
    def open_transfer_drawer
      execute_script("arguments[0].click()", find(@row_link, visible: :all, match: :first))
      within("dialog[open]") { assert_link @account.name }
    end

    def leave_the_list_and_come_back
      find("a[href='#{reports_path}']", match: :first).click
      assert_selector "h1", text: I18n.t("reports.index.title")

      page.go_back
      assert_selector "main h1", text: "Transactions"
    end
end
