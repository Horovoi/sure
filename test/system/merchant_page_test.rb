require "application_system_test_case"

# The merchant page: open it from a transaction row, filter it, and come back to it
# after editing the merchant.
class MerchantPageTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
    @entry = accounts(:depository).entries.create!(
      name: "Netflix March", amount: 15.99, currency: "USD", date: Date.current,
      entryable: Transaction.new(merchant: @merchant)
    )
    accounts(:credit_card).entries.create!(
      name: "Netflix April", amount: 15.99, currency: "USD", date: 1.day.ago.to_date,
      entryable: Transaction.new(merchant: @merchant)
    )
  end

  test "open the merchant page from a transaction row and return to it after an edit" do
    visit transactions_url

    within "##{dom_id(@entry)}" do
      click_link @merchant.name, match: :first
    end

    assert_selector "h1", text: @merchant.name
    assert_text "Netflix March"
    assert_text "Netflix April"

    click_link I18n.t("family_merchants.show.edit")
    within "#modal" do
      fill_in "family_merchant[name]", with: "Netflix Premium"
      find("button[type=submit]").click
    end

    assert_selector "h1", text: "Netflix Premium"
    assert_current_path family_merchant_path(@merchant)
  end

  test "search narrows the list and the summary" do
    visit family_merchant_url(@merchant)

    fill_in I18n.t("family_merchants.show.search_placeholder"), with: "March"

    assert_no_text "Netflix April"
    assert_text "Netflix March"
  end
end
