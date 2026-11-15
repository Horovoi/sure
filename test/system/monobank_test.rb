require "application_system_test_case"

class MonobankTest < ApplicationSystemTestCase
  include MonobankTestHelper

  setup do
    enable_bank_connections(:monobank)
    setup_monobank_family
    @card = create_monobank_product(account_id: "uah-card", balance: 4_200_000, credit_limit: 5_000_000)
    @usd = create_monobank_product(account_id: "usd-card", currency: "USD", balance: 12_345)
    @jar = create_monobank_product(account_id: "jar-1", kind: "jar", title: "Відпустка", balance: 150_000)
    @item.refresh_pending_account_setup!
    @visa = create_sure_account(name: "Mono Visa", accountable_type: "CreditCard")
    add_manual_transaction(@visa, date: 3.days.ago.to_date, amount: 100)

    sign_in users(:family_admin)
  end

  test "set up the accounts: link Mono Visa, create the rest, see where its transactions come from" do
    visit accounts_path
    click_on I18n.t("monobank_items.monobank_item.setup_action")

    within "dialog" do
      assert_text I18n.t("monobank_items.setup_accounts.title")
      assert_equal "link:#{@visa.id}", find("#setup_#{@card.id}_choice").value
      assert_equal 2.days.ago.to_date.iso8601, find("#setup_#{@card.id}_cutover").value
      find("#setup_#{@jar.id}_choice").select(I18n.t("monobank_items.setup_choices.skip"))
      click_on I18n.t("monobank_items.setup_accounts.submit")
    end

    assert_text "Done: 1 created, 1 linked, 1 skipped."
    assert_equal @visa, @card.reload.current_account
    assert_equal 2.days.ago.to_date, @visa.reload.provider_cutover_date
    assert_equal "USD", @usd.reload.current_account.currency
    assert @jar.reload.ignored?

    visit account_path(@visa)
    assert_selector "[data-testid='provider-cutover-text']", text: "come from monobank. Earlier history is kept as you entered it."
  end
end
