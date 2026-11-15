require "application_system_test_case"

class TransfersTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    visit transactions_url
  end

  test "can create a transfer" do
    checking_name = accounts(:depository).name
    savings_name = accounts(:credit_card).name
    transfer_date = Date.current

    click_on "New transaction"

    # Will navigate to different route in same modal
    click_on "Transfer"
    assert_text "New transfer"

    select checking_name, from: "From"
    select savings_name, from: "To"
    fill_in "transfer[amount]", with: 500
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-" + transfer_date.to_s do
      assert_text "Payment to"
    end
  end

  # w2-transfers custom-exchange-rate
  test "a UAH to USD transfer with the bank's rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    uah = @user.family.accounts.create!(name: "Hryvnia card", balance: 50_000, currency: "UAH", accountable: Depository.new)
    usd = accounts(:depository)
    ExchangeRate.create!(from_currency: "UAH", to_currency: "USD", date: Date.current, rate: 0.0241)

    visit new_transfer_url

    assert_no_selector "[data-testid=exchange-rate-tabs]", visible: true

    select uah.name, from: "From"
    select usd.name, from: "To"
    fill_in "transfer[amount]", with: "4150"

    within "[data-testid=exchange-rate-tabs]" do
      assert_text "Market rate on #{Date.current.iso8601}"
      click_on "Converted amount"
      fill_in "transfer_converted_amount", with: "99.6"
      assert_text "1 UAH = 0.024 USD"
    end

    click_button "Create transfer"

    transfer = Transfer.order(:created_at).last
    assert_equal uah, transfer.from_account
    assert_equal(-99.6, transfer.inflow_transaction.entry.amount.to_f)
    assert_equal 4_150, transfer.outflow_transaction.entry.amount
  end

  test "the rate tabs stay hidden for two accounts in one currency" do
    visit new_transfer_url

    select accounts(:depository).name, from: "From"
    select accounts(:credit_card).name, from: "To"

    assert_no_selector "[data-testid=exchange-rate-tabs]", visible: true
  end

  # w2-transfers transfer-hints
  test "rejecting a pending match on an account page needs no page reload" do
    outflow = accounts(:depository).entries.create!(name: "Pending match out", date: Date.current, amount: 432, currency: "USD", entryable: Transaction.new)
    inflow = accounts(:credit_card).entries.create!(name: "Pending match in", date: Date.current, amount: -432, currency: "USD", entryable: Transaction.new)
    Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "pending")

    visit account_url(accounts(:depository))
    page.execute_script("window.__sameDocument = true")

    within "##{ActionView::RecordIdentifier.dom_id(outflow)}" do
      assert_selector "[data-testid=transfer-match-pill]"
      find("button[aria-label='Reject match']").click
    end

    within "##{ActionView::RecordIdentifier.dom_id(outflow)}" do
      assert_no_selector "[data-testid=transfer-match-pill]"
    end
    assert page.evaluate_script("window.__sameDocument === true"), "the page was reloaded"
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "the Transfer? hint opens the matcher and Not a transfer removes it in place" do
    outflow = accounts(:depository).entries.create!(name: "Hint out", date: Date.current, amount: 543, currency: "USD", entryable: Transaction.new)
    accounts(:credit_card).entries.create!(name: "Hint in", date: Date.current, amount: -543, currency: "USD", entryable: Transaction.new)

    visit transactions_url

    within "##{ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)}" do
      click_on "Transfer?"
    end
    assert_text "Match transfer or payment"

    visit transactions_url
    page.execute_script("window.__sameDocument = true")

    within "##{ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)}" do
      find("button[aria-label='Not a transfer']").click
    end

    assert_no_selector "##{ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)}"
    assert page.evaluate_script("window.__sameDocument === true"), "the page was reloaded"
  end
end
