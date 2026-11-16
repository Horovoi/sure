require "application_system_test_case"

# Confirmation bodies interpolate names that come from imports, providers and
# other family members, so the dialog has to show them as text.
class ConfirmDialogTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as @user
  end

  test "shows a provider merchant's name as text instead of rendering it" do
    # A name no fixture merchant shares (the fixtures have "Starbucks Coffee")
    name = %(<img src=x onerror="document.body.dataset.injected='yes'"> Corner roaster)
    merchant = ProviderMerchant.create!(name: name, source: "ai")
    Transaction.joins(entry: :account).where(accounts: { family_id: @user.family_id }).first.update!(merchant: merchant)

    visit family_merchants_path

    within "tr", text: "Corner roaster" do
      find("[data-DS--menu-target='button']").click
    end
    click_on I18n.t("family_merchants.provider_merchant.remove")

    within "#confirm-dialog" do
      assert_text I18n.t("family_merchants.provider_merchant.remove_confirm_body", name: name)
      assert_no_selector "img"
    end
    assert_nil page.evaluate_script("document.body.dataset.injected")
  end

  # Enter on open must never run the action, and closing the dialog any other way than
  # its confirm button is a no, also right after an earlier confirmation said yes
  test "a confirmation starts on Cancel and only its confirm button says yes" do
    visit root_path
    page.execute_script(<<~JS)
      window.__answers = [];
      window.__ask = () => window.Turbo.config.forms.confirm(
        JSON.stringify({ title: "Delete it?", variant: "destructive" })
      ).then((answer) => window.__answers.push(answer));
    JS

    page.execute_script("window.__ask()")
    within "#confirm-dialog" do
      assert_selector "button[value=confirm][data-variant=destructive]", text: I18n.t("layouts.shared.confirm_dialog.confirm")
      assert_equal "cancel", page.evaluate_script("document.activeElement.value")
      click_button I18n.t("layouts.shared.confirm_dialog.confirm")
    end
    assert_no_selector "#confirm-dialog[open]"

    page.execute_script("window.__ask()")
    within("#confirm-dialog") { find("button[aria-label='#{I18n.t("ds.dialog.close")}']").click }
    assert_no_selector "#confirm-dialog[open]"

    page.execute_script("window.__ask()")
    assert_selector "#confirm-dialog[open]"
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector "#confirm-dialog[open]"

    page.execute_script("window.__ask()")
    within("#confirm-dialog") { click_button I18n.t("layouts.shared.confirm_dialog.cancel") }
    assert_no_selector "#confirm-dialog[open]"

    assert_equal [ true, false, false, false ], page.evaluate_script("window.__answers")
  end

  test "falls back to the translated defaults when a confirmation sets no body" do
    visit root_path

    page.execute_script(<<~JS)
      window.Turbo.config.forms.confirm("true")
    JS

    within "#confirm-dialog" do
      assert_text I18n.t("layouts.shared.confirm_dialog.title")
      assert_text I18n.t("layouts.shared.confirm_dialog.body")
      assert_selector "button", text: I18n.t("layouts.shared.confirm_dialog.confirm")
    end
  end
end
