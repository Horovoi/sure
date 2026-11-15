require "application_system_test_case"

# The money field is a text input: a comma decimal, a calculation and a pasted
# statement amount all save the plain number. The +/−/×/÷ row under it belongs
# to that field only (an unnamed group-focus-within used to match every
# DS::Disclosure, so focusing the drawer's name showed the row too).
class MoneyFieldOperatorsTest < ApplicationSystemTestCase
  OPERATOR_ROW = "button[aria-label='#{I18n.t("shared.money_field.operator_add")}']".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    @account = accounts(:depository)
  end

  test "the operator row shows for the transaction drawer's amount, not its name" do
    entry = transactions(:one).entry

    visit transactions_url
    page.execute_script <<~JS
      document.querySelector("turbo-frame#drawer").src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer" do
      find_field("entry[name]").click
      assert_no_selector OPERATOR_ROW

      find_field("entry[amount]").click
      assert_selector OPERATOR_ROW

      find_field("entry[name]").click
      assert_no_selector OPERATOR_ROW
    end
  end

  test "the operator row stays reachable by Tab from the new transaction's amount" do
    visit new_transaction_url

    fill_in "entry[name]", with: "Groceries"
    assert_no_selector OPERATOR_ROW

    find_field("entry[amount]").click
    assert_selector OPERATOR_ROW

    # Amount → currency select → first operator button.
    find_field("entry[amount]").send_keys(:tab)
    page.driver.browser.action.send_keys(:tab).perform
    assert_equal I18n.t("shared.money_field.operator_add"), page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    fill_in "entry[name]", with: "Groceries"
    assert_no_selector OPERATOR_ROW
  end

  test "a comma decimal saves the amount, and a currency change keeps what was typed" do
    entry = create_transaction("Market") do
      fill_in "entry[amount]", with: "12,50"
      select "UAH", from: "entry[currency]"

      # Switching the currency never rewrites the typed amount.
      assert_field "entry[amount]", with: "12,50"
    end

    assert_equal 12.5.to_d, entry.amount
    assert_equal "UAH", entry.currency
  end

  test "a calculation saves its result" do
    entry = create_transaction("Split bill") do
      fill_in "entry[amount]", with: "120+35,5"
      find_field("entry[name]").click

      assert_field "entry[amount]", with: "155,50"
    end

    assert_equal 155.5.to_d, entry.amount
  end

  test "a pasted statement amount with spaces and a hryvnia sign saves the plain number" do
    entry = create_transaction("Rent") do
      paste_into "entry[amount]", "1 234,56 ₴"

      assert_field "entry[amount]", with: "1234.56"
    end

    assert_equal 1234.56.to_d, entry.amount
  end

  test "an amount that is not a number or calculation blocks the save" do
    visit new_transaction_url
    fill_in "entry[name]", with: "Typo"
    select @account.name, from: "entry[account_id]"
    fill_in "entry[amount]", with: "100-"

    assert_no_difference "Entry.count" do
      click_button I18n.t("transactions.form.submit")
      assert_selector "input[name='entry[amount]']:invalid"
    end
  end

  private
    # Fills the new-transaction form around the block (which sets the amount),
    # saves it and returns the new entry.
    def create_transaction(name)
      visit new_transaction_url
      fill_in "entry[name]", with: name
      select @account.name, from: "entry[account_id]"

      yield

      assert_difference "Entry.count", +1 do
        click_button I18n.t("transactions.form.submit")
        assert_text "Transaction created"
      end

      Entry.order(:created_at).last
    end

    def paste_into(field_name, text)
      field = find_field(field_name)
      field.click
      page.execute_script(<<~JS, field.native, text)
        const [input, text] = arguments
        const data = new DataTransfer()
        data.setData("text", text)
        input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
      JS
    end
end
