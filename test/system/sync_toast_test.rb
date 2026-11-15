require "application_system_test_case"

class SyncToastTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "an open new-transaction form keeps its input and the toast waits for a manual refresh" do
    visit account_path(@account)
    within_testid("activity-menu") { click_on I18n.t("accounts.show.activity.new") }
    click_on I18n.t("accounts.show.activity.new_transaction")

    within "dialog[open]" do
      fill_in "entry_name", with: "Half-typed coffee"
    end

    # A long delay, so the toast is still up when the test looks for it after the dialog closes
    deliver_sync_toast(auto_refresh_delay: 60_000)
    sleep 1

    # Deferred behind the dialog: no refresh, the typed value is still there
    within "dialog[open]" do
      assert_field "entry_name", with: "Half-typed coffee"
    end
    assert_selector "#sync-toast[role='status']", visible: :hidden

    find("dialog[open]").send_keys(:escape)

    within "#sync-toast" do
      assert_button I18n.t("shared.sync_toast.refresh")
      assert_selector "button[aria-label='#{I18n.t("shared.sync_toast.close")}']"
    end
  end

  test "a focused form outside a dialog keeps the toast up instead of refreshing" do
    visit account_path(@account)
    mark_window

    find("input[name='q[search]']").click
    deliver_sync_toast(auto_refresh_delay: 100)
    sleep 1

    within "#sync-toast" do
      assert_button I18n.t("shared.sync_toast.refresh")
    end
    assert page.evaluate_script("window.__syncToastMarker === true"), "the page must not reload"
  end

  test "an idle dashboard morphs to the new balance" do
    # Nothing focused: the chat panel's input would count as a form in progress
    @user.update!(show_ai_sidebar: false)
    visit root_path
    page.execute_script("document.activeElement?.blur()")
    mark_window
    assert_no_text "$7,777.00"

    @account.update!(balance: 7777)
    deliver_sync_toast(auto_refresh_delay: 100)

    assert_text "$7,777.00"
    assert_no_selector "#sync-toast[role='status']", visible: :all
    assert page.evaluate_script("window.__syncToastMarker === true"), "the refresh must be a Turbo morph, not a full reload"
  end

  test "closing the toast leaves the slot for the next sync" do
    visit account_path(@account)
    find("input[name='q[search]']").click
    deliver_sync_toast(auto_refresh_delay: 60_000)

    find("#sync-toast button[aria-label='#{I18n.t("shared.sync_toast.close")}']").click
    assert_no_selector "#sync-toast[role='status']", visible: :all
    assert_selector "#sync-toast", visible: :all

    find("input[name='q[search]']").click
    deliver_sync_toast(auto_refresh_delay: 60_000)
    within("#sync-toast") { assert_button I18n.t("shared.sync_toast.refresh") }
  end

  private
    # The test cable adapter does not reach the browser, so the stream that
    # Family::SyncCompleteEvent broadcasts is rendered here and handed to Turbo.
    def deliver_sync_toast(auto_refresh_delay:)
      toast = ApplicationController.render(partial: "shared/notifications/sync_toast")
      toast = toast.sub('data-controller="sync-toast"', %(data-controller="sync-toast" data-sync-toast-auto-refresh-delay-value="#{auto_refresh_delay}"))
      stream = %(<turbo-stream action="replace" target="sync-toast"><template>#{toast}</template></turbo-stream>)

      page.execute_script("Turbo.renderStreamMessage(arguments[0])", stream)
    end

    # A full page reload clears window properties; a Turbo visit keeps them
    def mark_window
      page.execute_script("window.__syncToastMarker = true")
    end
end
