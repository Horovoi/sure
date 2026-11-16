require "application_system_test_case"

# The new-transaction dialog's Expense / Income / Transfer tabs load another form
# into the same modal. The dialog must stay open through the switch (its backdrop
# used to blink off and on), and opening it must not ring the close button.
class DialogTabsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "switching tabs keeps the same dialog open and modal" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    assert_selector "dialog[open]"

    page.execute_script(<<~JS)
      window.__dialog = document.querySelector("#modal dialog[open]");
      window.__closed = 0;
      window.__dialog.addEventListener("close", () => window.__closed += 1);
    JS

    within("dialog[open]") { click_on "Income" }
    assert_selector "dialog[open] input[name='entry[nature]'][value=inflow]", visible: :all
    within("dialog[open]") { click_on "Transfer" }
    assert_selector "dialog[open] [name='transfer[amount]']", visible: :all
    within("dialog[open]") { click_on "Expense" }
    assert_selector "dialog[open] input[name='entry[nature]'][value=outflow]", visible: :all

    assert evaluate_script("document.querySelector('#modal dialog[open]') === window.__dialog"), "the dialog was replaced"
    assert evaluate_script("window.__dialog.matches(':modal')"), "the dialog is no longer modal"
    assert_equal 0, evaluate_script("window.__closed")
  end

  test "the dialog opens with focus on itself, not on the close button" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    assert_selector "dialog[open]"

    assert evaluate_script("document.activeElement === document.querySelector('#modal dialog[open]')")
    # The first Tab reaches the first control in the dialog
    find("dialog[open]").send_keys(:tab)
    assert evaluate_script("document.querySelector('#modal dialog[open]').contains(document.activeElement)")
  end
end
