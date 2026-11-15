require "application_system_test_case"

class ConvertToTradeTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)

    # No price provider to search: the form offers the account's holdings,
    # or a plain ticker field when there are none.
    Security.stubs(:provider).returns(nil)
    @account = accounts(:investment)
    @entry = create_transaction(account: @account, name: "Brokerage deposit", amount: 100)
  end

  # Cancel used to be a link-style button, which renders a form of its own.
  # Nested in the conversion form, the browser handed its submit button to
  # that form, so Cancel on a filled-in dialog created the trade.
  test "cancel closes a filled-in convert dialog without converting" do
    @account.holdings.delete_all
    open_convert_dialog

    assert_no_difference -> { Trade.count } do
      within conversion_form do
        fill_in "ticker", with: "AAPL"
        fill_in "qty", with: "1"
        fill_in "price", with: "100"
        click_on I18n.t("transactions.convert_to_trade.cancel")
      end

      assert_no_selector conversion_form
    end

    assert_kind_of Transaction, @entry.reload.entryable
  end

  test "cancel with a custom ticker picked from the holdings list does not convert" do
    assert @account.holdings.exists?, "the investment fixture needs a holding for the holdings select"
    open_convert_dialog

    assert_no_difference -> { Trade.count } do
      within conversion_form do
        find("select[name='security_id']").select(I18n.t("transactions.convert_to_trade.security_custom"))
        fill_in "custom_ticker", with: "VWRA"
        fill_in "qty", with: "2"
        fill_in "price", with: "50"
        click_on I18n.t("transactions.convert_to_trade.cancel")
      end

      assert_no_selector conversion_form
    end

    assert_kind_of Transaction, @entry.reload.entryable
  end

  private
    def open_convert_dialog
      visit transaction_path(@entry)
      find("summary", text: /#{I18n.t("transactions.show.settings")}/i).click
      # The fork's transaction page shows this button as literal English text
      click_on "Convert"

      assert_selector conversion_form
    end

    def conversion_form
      "form[action='#{create_trade_from_transaction_transaction_path(@entry.entryable)}']"
    end
end
