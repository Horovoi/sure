require "application_system_test_case"

# DS::Tabs rewrites the URL through utils/replace_url, which keeps Turbo's own
# idea of the current URL in step. A raw history.replaceState left Turbo with
# the old URL, so Back to the tab's URL refetched the page instead of restoring
# the copy it had cached.
class ReplaceUrlBackTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "Back after a tab switch restores the account page as it was left" do
    account = accounts(:investment)
    visit account_path(account)
    find("[role='tab']", text: "Holdings").click
    assert_current_path account_path(account, tab: "holdings")

    # Only the copy Turbo caches on leaving carries this mark. A refetch drops it.
    execute_script("document.body.dataset.left = ''")
    click_link "Transactions"
    assert_selector "main h1", text: "Transactions"

    page.go_back

    assert_selector "body[data-left]"
    assert_selector "[role='tab'][aria-selected='true']", text: "Holdings"
    assert_current_path account_path(account, tab: "holdings")
  end

  test "arrow keys move focus across the tabs and Enter activates one" do
    visit account_path(accounts(:investment))

    activity = find("[role='tab']", text: "Activity")
    activity.click
    activity.send_keys(:arrow_right)

    holdings = find("[role='tab']", text: "Holdings")
    assert_equal holdings[:id], evaluate_script("document.activeElement.id")
    assert_selector "[role='tab'][aria-selected='true']", text: "Activity"

    holdings.send_keys(:enter)

    assert_selector "[role='tab'][aria-selected='true'][tabindex='0']", text: "Holdings"
    assert_current_path account_path(accounts(:investment), tab: "holdings")
  end
end
