require "application_system_test_case"

class CreditCardsTest < ApplicationSystemTestCase
  include BalanceTestHelper

  setup do
    sign_in users(:family_admin)
    @account = accounts(:credit_card)
    @account.accountable.update!(statement_close_day: nil, due_day: nil, apr: nil, minimum_payment: nil)
    create_balance(account: @account, date: 2.months.ago.to_date, balance: 1_000)
  end

  test "set the statement cycle days and see the overview figures" do
    visit account_path(@account)

    click_on I18n.t("UI.account_page.tabs.overview")
    assert_text I18n.t("credit_cards.tabs.overview.no_cycle_title")

    click_on I18n.t("credit_cards.tabs.overview.edit_card_details")

    within "dialog" do
      find("select[name='account[accountable_attributes][statement_close_day]']").select("25th")
      find("select[name='account[accountable_attributes][due_day]']").select("5th")
      find("[type='submit']").click
    end

    assert_no_selector "dialog[open]"
    assert_equal [ 25, 5 ], [ @account.accountable.reload.statement_close_day, @account.accountable.due_day ]

    click_on I18n.t("UI.account_page.tabs.overview")

    within "[data-testid='credit-card-statement-balance']" do
      assert_text I18n.t("credit_cards.tabs.overview.statement_balance")
      assert_text "$1,000.00"
      assert_text(/#{Regexp.escape(I18n.t("credit_cards.tabs.overview.due_on", date: ""))}/)
    end

    within "[data-testid='credit-card-since-last-statement']" do
      assert_text I18n.t("credit_cards.tabs.overview.since_last_statement")
      assert_text "$0.00"
    end
  end
end
