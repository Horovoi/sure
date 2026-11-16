require "application_system_test_case"

class SplitTransactionsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    @entry = create_transaction(account: accounts(:depository), name: "Hardware store", amount: 80)
    sign_in @user
  end

  test "split a transaction in the editor, see it grouped, and unsplit it" do
    visit transactions_path
    click_link "Hardware store"
    find("dialog[open] summary", text: /settings/i).click
    within("dialog[open]") { click_link "Split" }

    within "form[data-controller='split-editor']" do
      assert_button "Split", disabled: true
      assert_text "Every part needs an amount other than 0"

      find("input[name='split[parts][0][amount]']").fill_in(with: "50")
      assert_text "$30.00 left to assign"

      all("input[name$='[name]']")[1].fill_in(with: "Paint")
      all("button", text: "Rest here")[1].click
      assert_equal "30.00", find("input[name='split[parts][1][amount]']").value
      assert_text "The parts add up to the total"

      click_button "Split"
    end

    assert_text "Transaction split"
    within "[data-testid=split-group]" do
      assert_link "Hardware store"
      assert_text "2 parts"
      assert_link "Paint"
    end
    assert_equal [ 50, 30 ], @entry.reload.child_entries.map(&:amount)

    click_link "Paint"
    assert_selector "dialog[open]", text: "Part of a split transaction"
    within("dialog[open]") { click_link "Hardware store" }
    assert_selector "dialog[open]", text: "Split into 2 parts"
    within("dialog[open]") { click_button "Unsplit" }
    within("#confirm-dialog") { click_button "Unsplit" }

    assert_text "Transaction unsplit"
    assert_no_selector "[data-testid=split-group]"
    assert_not @entry.reload.split_parent?
  end
end
