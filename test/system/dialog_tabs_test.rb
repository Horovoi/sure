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

  # A switch draws the other form at once: nothing in the dialog animates into place
  # (a morph reused the old fields and their transitions slid them about), and focus
  # stays in the dialog instead of falling to the page
  test "a tab switch swaps the form in one step" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    within("dialog[open]") { click_on "Transfer" }
    assert_selector "dialog[open] [name='transfer[amount]']", visible: :all

    moving = evaluate_script(<<~JS)
      document.getAnimations()
        .filter((a) => document.querySelector("#modal dialog[open]").contains(a.effect?.target))
        .map((a) => a.transitionProperty || a.animationName)
    JS
    assert_empty moving
    assert evaluate_script("document.activeElement === document.querySelector('#modal dialog[open]')")
  end

  # The description is a combobox from a gem; its text matches the other fields
  test "the description reads in the same size as the other fields" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    assert_selector "dialog[open] .hw-combobox__input"

    sizes = evaluate_script(<<~JS)
      [".hw-combobox__input", "select[name='entry[account_id]']", "input[name='entry[amount]']"]
        .map((css) => document.querySelector("#modal dialog[open] " + css))
        .map((el) => el && getComputedStyle(el).fontSize)
    JS
    assert_equal 1, sizes.compact.uniq.size, sizes.inspect
  end

  # Every field of both forms is one height, a category picked or not, and the dialog
  # hangs from the top, so the title and tabs do not move when the form changes
  test "fields share one height and the title stays put across a switch" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    assert_selector "dialog[open] .hw-combobox__input"

    # A picked category's badge keeps the field at the others' height
    find("dialog[open] [data-category-select-target=button]").click
    find("dialog[open] [role=option]", match: :first).click
    assert_selector "dialog[open] .category-select__selection [data-category-badge]"

    expense = field_heights
    assert_equal 1, expense.uniq.size, expense.inspect
    title_top = dialog_title_top

    within("dialog[open]") { click_on "Transfer" }
    assert_selector "dialog[open] [name='transfer[amount]']", visible: :all
    transfer = field_heights
    assert_equal [ expense.first ], transfer.uniq, transfer.inspect
    assert_equal title_top, dialog_title_top

    # From and To are required, and marked so like the transaction form's Account
    assert_selector "dialog[open] label", text: /\AFrom\s*\*\z/
    assert_selector "dialog[open] label", text: /\ATo\s*\*\z/
  end

  # The tabs morph the form: the amount input the money field guards can be swapped
  # under it, and its checks must follow the new input
  test "after a tab switch the amount field still refuses a second decimal separator" do
    visit transactions_path
    click_on I18n.t("transactions.index.new_transaction", default: "New transaction"), match: :first
    within("dialog[open]") { click_on "Income" }
    assert_selector "dialog[open] input[name='entry[nature]'][value=inflow]", visible: :all

    field = find("dialog[open] input[name='entry[amount]']")
    field.send_keys("10.5")
    field.send_keys(".")
    assert_equal "10.5", field.value
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

  private
    # Heights of the visible single-line fields (notes and the details section aside)
    def field_heights
      evaluate_script(<<~JS)
        [...document.querySelectorAll("#modal dialog[open] .form-field")]
          .filter((f) => f.offsetParent !== null && !f.querySelector("textarea"))
          .map((f) => Math.round(f.getBoundingClientRect().height))
      JS
    end

    def dialog_title_top
      evaluate_script("Math.round(document.querySelector('#modal dialog[open] h2').getBoundingClientRect().top)")
    end
end
