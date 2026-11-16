require "application_system_test_case"

# Behaviour of the DS menu and dialog primitives that every page relies on.
class DsOverlaysTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as @user
  end

  test "a menu closes before the confirm dialog of a button_to item opens" do
    merchant = ProviderMerchant.create!(name: "Corner roaster", source: "ai")
    Transaction.joins(entry: :account).where(accounts: { family_id: @user.family_id }).first.update!(merchant: merchant)

    visit family_merchants_path

    menu = nil
    within "tr", text: "Corner roaster" do
      find("[data-DS--menu-target='button']").click
      menu = find("[data-DS--menu-target='content']")
    end
    click_on I18n.t("family_merchants.provider_merchant.remove")

    assert_selector "#confirm-dialog[open]"
    assert menu.matches_css?(".hidden", visible: :all), "the menu is closed under the confirm dialog"
    assert_equal "false", page.find("tr", text: "Corner roaster").find("[data-DS--menu-target='button']")[:"aria-expanded"]
  end

  test "open() and a direct showModal() both focus the dialog itself, not its close button" do
    visit root_path

    focused = page.evaluate_script(<<~JS)
      (() => {
        const dialog = document.getElementById("confirm-dialog")
        window.Stimulus.getControllerForElementAndIdentifier(dialog, "DS--dialog").open()
        return document.activeElement === dialog
      })()
    JS
    assert focused, "open() leaves focus on the dialog"

    page.execute_script(<<~JS)
      document.getElementById("confirm-dialog").close()
      document.getElementById("confirm-dialog").showModal()
    JS

    # The observer runs right after showModal() returns
    assert page.evaluate_script(%(document.activeElement === document.getElementById("confirm-dialog"))),
      "a direct showModal() also leaves focus on the dialog"
  end
end
