require "application_system_test_case"

class TradesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)

    @user.update!(show_sidebar: false, show_ai_sidebar: false)

    @account = accounts(:investment)

    visit_account_portfolio

    # Disable provider to focus on form testing
    Security.stubs(:provider).returns(nil)
  end

  test "can create buy transaction" do
    shares_qty = 25

    open_new_trade_modal

    fill_in "Ticker symbol", with: "AAPL"
    fill_in "Date", with: Date.current
    fill_in "Quantity", with: shares_qty
    fill_in "model[price]", with: 214.23

    click_button "Add transaction"
    wait_for_trade_saved

    visit_trades

    within_trades do
      assert_text "Buy #{shares_qty}.0 shares of AAPL"
    end
  end

  test "can create sell transaction" do
    qty = 10
    aapl = @account.holdings.find { |h| h.security.ticker == "AAPL" }

    open_new_trade_modal

    select "Sell", from: "Type"
    fill_in "Ticker symbol", with: "AAPL"
    fill_in "Date", with: Date.current
    fill_in "Quantity", with: qty
    fill_in "model[price]", with: 215.33

    click_button "Add transaction"
    wait_for_trade_saved

    visit_trades

    within_trades do
      assert_text "Sell #{qty}.0 shares of AAPL"
    end
  end

  # --- Money field (w1-ds): text input with calculations and comma decimals ---

  test "rejects a negative cost per share on an existing trade" do
    entry = entries(:trade)
    trade = entry.trade
    original_price = trade.price

    visit trade_path(entry)

    # The money field is a text input, so money_field_controller enforces the
    # field's min: 0. requestSubmit() from auto_submit_form runs constraint
    # validation, so an invalid form never dispatches "submit".
    page.execute_script(<<~JS, find_field(I18n.t("trades.show.cost_per_share_label")))
      const form = arguments[0].form;
      window.tradeFormSubmitAttempts = 0;
      window.tradeFormSubmits = 0;
      const requestSubmit = form.requestSubmit.bind(form);
      form.requestSubmit = (...args) => {
        window.tradeFormSubmitAttempts++;
        return requestSubmit(...args);
      };
      form.addEventListener("submit", () => window.tradeFormSubmits++);
    JS

    within "dialog[open]" do
      fill_in I18n.t("trades.show.cost_per_share_label"), with: "-5"
      find_field(I18n.t("trades.show.cost_per_share_label")).send_keys(:tab)
      assert_equal I18n.t("shared.money_field.below_min", min: 0),
        find_field(I18n.t("trades.show.cost_per_share_label")).evaluate_script("this.validationMessage")
    end

    assert_eventually { page.evaluate_script("window.tradeFormSubmitAttempts") >= 1 }
    assert_equal 0, page.evaluate_script("window.tradeFormSubmits")
    assert_equal original_price, trade.reload.price
  end

  test "auto-saves a comma-decimal calculation as the cost per share" do
    entry = entries(:trade)
    trade = entry.trade

    visit trade_path(entry)

    within "dialog[open]" do
      fill_in I18n.t("trades.show.cost_per_share_label"), with: "200+14,5"
      find_field(I18n.t("trades.show.cost_per_share_label")).send_keys(:tab)
    end

    assert_eventually { trade.reload.price.to_d == 214.5.to_d }
  end

  private
    def assert_eventually(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
      pass
    end

    # Leaving the page before the create request finishes loses the trade
    def wait_for_trade_saved
      assert_text I18n.t("entries.create.success")
    end

    def open_new_trade_modal
      click_on "New transaction"
    end

    def within_trades(&block)
      within "#" + dom_id(@account, "entries"), &block
    end

    def visit_trades
      visit account_path(@account, tab: "activity")
    end

    def visit_account_portfolio
      visit account_path(@account, tab: "holdings")
    end
end
