require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "should get new" do
    get new_transfer_url
    assert_response :success
  end

  test "can create transfers" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          name: "Test Transfer"
        }
      }
      assert_enqueued_with job: SyncJob
    end
  end

  test "soft deletes transfer" do
    assert_difference -> { Transfer.count }, -1 do
      delete transfer_url(transfers(:one))
    end
  end

  test "removing a transfer records a rejection so auto-match does not pair it again" do
    transfer = transfers(:one)

    assert_difference -> { RejectedTransfer.count } => 1, -> { Transfer.count } => -1 do
      delete transfer_url(transfer)
    end

    assert_equal "standard", transactions(:transfer_in).reload.kind
    assert_equal "standard", transactions(:transfer_out).reload.kind
  end

  test "removing a transfer twice returns not found" do
    transfer = transfers(:one)
    delete transfer_url(transfer)
    delete transfer_url(transfer)

    assert_response :not_found
  end

  test "confirming an already confirmed transfer is harmless" do
    transfer = transfers(:one)
    transfer.confirm!

    patch transfer_url(transfer), params: { transfer: { status: "confirmed" } }

    assert transfer.reload.confirmed?
  end

  test "can add notes to transfer" do
    transfer = transfers(:one)
    assert_nil transfer.notes

    patch transfer_url(transfer), params: { transfer: { notes: "Test notes" } }

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]
    assert_equal "Test notes", transfer.reload.notes
  end

  test "handles rejection without FrozenError" do
    transfer = transfers(:one)

    assert_difference "Transfer.count", -1 do
      patch transfer_url(transfer), params: {
        transfer: {
          status: "rejected"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]

    # Verify the transfer was actually destroyed
    assert_raises(ActiveRecord::RecordNotFound) do
      transfer.reload
    end
  end

  test "creates a transfer from an ISO date" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: 2.days.ago.to_date.iso8601,
          amount: 100
        }
      }
    end

    assert_equal 2.days.ago.to_date, Transfer.order(:created_at).last.date
    assert_equal "Transfer created", flash[:notice]
  end

  test "a blank transfer date shows the form again" do
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: "",
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "Date can&#39;t be blank", response.body
  end

  test "a bad transfer date shows the form again instead of a server error" do
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: "not-a-date",
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "Date is invalid", response.body
  end

  test "the new transfer form lists only visible accounts" do
    disabled_account = accounts(:depository)
    disabled_account.update_column(:status, "disabled")

    get new_transfer_url

    assert_response :success
    assert_select "select[name='transfer[from_account_id]'] option[value='#{disabled_account.id}']", count: 0
    assert_select "select[name='transfer[to_account_id]'] option[value='#{disabled_account.id}']", count: 0
    assert_select "select[name='transfer[from_account_id]'] option[value='#{accounts(:credit_card).id}']"
  end

  # --- DS pickers (w1-ds) ---

  test "confirming a transfer keeps its notes and category" do
    transfer = transfers(:one)
    category = categories(:food_and_drink)
    transfer.update!(notes: "Rent split")
    transfer.outflow_transaction.update!(category: category)

    patch transfer_url(transfer), params: { transfer: { status: "confirmed" } }

    assert_equal "Rent split", transfer.reload.notes
    assert_equal category, transfer.outflow_transaction.reload.category
  end

  test "setting a transfer's category records it as recently used" do
    transfer = transfers(:one)
    category = categories(:food_and_drink)

    patch transfer_url(transfer), params: { transfer: { category_id: category.id, notes: "" } }

    assert_equal category, transfer.outflow_transaction.reload.category
    assert_not_nil category.reload.last_used_at
  end

  # w2-transfers custom-exchange-rate
  test "creates a cross-currency transfer at the user's rate" do
    family = users(:family_admin).family
    uah = family.accounts.create!(name: "UAH card", balance: 10_000, currency: "UAH", accountable: Depository.new)

    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: { from_account_id: uah.id, to_account_id: accounts(:depository).id, date: Date.current, amount: 4_150, exchange_rate: "0,024" }
      }
    end

    transfer = Transfer.order(:created_at).last
    assert_equal BigDecimal("-99.6"), transfer.inflow_transaction.entry.amount
  end

  test "creates a cross-currency transfer with the received amount" do
    family = users(:family_admin).family
    uah = family.accounts.create!(name: "UAH card", balance: 10_000, currency: "UAH", accountable: Depository.new)

    post transfers_url, params: {
      transfer: { from_account_id: uah.id, to_account_id: accounts(:depository).id, date: Date.current, amount: 4_150, destination_amount: "100" }
    }

    assert_equal(-100, Transfer.order(:created_at).last.inflow_transaction.entry.amount)
  end

  test "a bad exchange rate shows the form again" do
    family = users(:family_admin).family
    uah = family.accounts.create!(name: "UAH card", balance: 10_000, currency: "UAH", accountable: Depository.new)

    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: { from_account_id: uah.id, to_account_id: accounts(:depository).id, date: Date.current, amount: 100, exchange_rate: "-1" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=exchange-rate-tabs]"
  end

  # w2-transfers transfer-fees
  test "creates a transfer with fees" do
    family = users(:family_admin).family
    savings = family.accounts.create!(name: "Fee savings", balance: 0, currency: "USD", accountable: Depository.new)

    assert_difference -> { Entry.count } => 3 do
      post transfers_url, params: {
        transfer: { from_account_id: accounts(:depository).id, to_account_id: savings.id, date: Date.current, amount: 100, source_fee: "2.5" }
      }
    end

    transfer = Transfer.order(:created_at).last
    assert_equal Money.new(2.5, "USD"), transfer.fee_money_for(:source)
  end

  test "the drawer lists the fees and edits them" do
    family = users(:family_admin).family
    savings = family.accounts.create!(name: "Fee savings", balance: 0, currency: "USD", accountable: Depository.new)
    transfer = Transfer::Creator.new(
      family: family, source_account_id: accounts(:depository).id, destination_account_id: savings.id,
      date: Date.current, amount: 100, source_fee: "2"
    ).create

    get transfer_url(transfer)
    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(transfer, :fees)}"
    assert_select "a", text: /Fee: Transfer to Fee savings/

    patch transfer_url(transfer), params: { transfer: { source_fee: "3", destination_fee: "1" } }, as: :turbo_stream
    assert_response :success
    assert_equal Money.new(3, "USD"), transfer.reload.fee_money_for(:source)
    assert_equal Money.new(1, "USD"), transfer.fee_money_for(:destination)

    patch transfer_url(transfer), params: { transfer: { source_fee: "", destination_fee: "1" } }
    assert_nil transfer.reload.fee_money_for(:source)
  end

  test "removing a transfer keeps its fees" do
    family = users(:family_admin).family
    savings = family.accounts.create!(name: "Fee savings", balance: 0, currency: "USD", accountable: Depository.new)
    transfer = Transfer::Creator.new(
      family: family, source_account_id: accounts(:depository).id, destination_account_id: savings.id,
      date: Date.current, amount: 100, source_fee: "2"
    ).create
    fee = transfer.fee_transactions.sole

    delete transfer_url(transfer)

    assert Transaction.exists?(fee.id)
    assert_nil fee.reload.fee_transfer_id
  end

  # w2-transfers transfer-hints
  def create_pending_match
    outflow = create_transaction(amount: 120, account: accounts(:depository))
    inflow = create_transaction(amount: -120, account: accounts(:credit_card))
    Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "pending")
  end

  test "rejecting a pending match from an account page redraws both rows with a turbo stream" do
    transfer = create_pending_match

    patch transfer_url(transfer), params: { transfer: { status: "rejected" } },
      headers: { "Referer" => account_url(accounts(:depository)) }, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, ActionView::RecordIdentifier.dom_id(transfer.outflow_transaction.entry)
    assert_includes response.body, ActionView::RecordIdentifier.dom_id(transfer.inflow_transaction.entry)
    assert_not_includes response.body, %(action="redirect")
    assert_not Transfer.exists?(transfer.id)
  end

  test "rejecting a pending match on the transactions list reloads the list" do
    transfer = create_pending_match

    patch transfer_url(transfer), params: { transfer: { status: "rejected" } },
      headers: { "Referer" => transactions_url }, as: :turbo_stream

    assert_response :success
    assert_includes response.body, %(action="redirect")
    assert_not Transfer.exists?(transfer.id)
  end

  test "the pending pill opens the transfer and names the other side" do
    transfer = create_pending_match

    get account_url(accounts(:depository))

    assert_response :success
    assert_select "a[href='#{transfer_path(transfer)}'][data-testid=transfer-match-pill]"
    assert_includes response.body, accounts(:credit_card).name
  end

  # --- w2-transfers transfer-form-fixes ---

  test "a failed create shows the form again with the entered accounts, amount and date" do
    date = 3.days.ago.to_date

    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: { from_account_id: accounts(:depository).id, to_account_id: accounts(:depository).id, date: date, amount: "250" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[type=hidden][name='transfer[from_account_id]'][value='#{accounts(:depository).id}']"
    assert_select "input[type=hidden][name='transfer[to_account_id]'][value='#{accounts(:depository).id}']"
    assert_select "input[name='transfer[amount]'][value='250.00']"
    assert_select "input[name='transfer[date]'][value='#{date.iso8601}']"
  end

  test "a create without a destination account is a form error, not a 404" do
    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: { from_account_id: accounts(:depository).id, to_account_id: "", date: Date.current, amount: "100" }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("activerecord.errors.models.transfer.attributes.base.accounts_required")
    assert_select "input[name='transfer[amount]'][value='100.00']"
  end

  test "a comma decimal amount is read, not cut at the comma" do
    post transfers_url, params: {
      transfer: { from_account_id: accounts(:depository).id, to_account_id: accounts(:credit_card).id, date: Date.current, amount: "41,5" }
    }

    assert_equal 41.5, Transfer.order(:created_at).last.outflow_transaction.entry.amount
  end

  test "new takes the values another tab carried over" do
    date = 2.days.ago.to_date

    get new_transfer_url(from_account_id: accounts(:depository).id, draft: { amount: "41,5", date: date.iso8601 })

    assert_response :success
    assert_select "input[type=hidden][name='transfer[from_account_id]'][value='#{accounts(:depository).id}']"
    assert_select "input[name='transfer[amount]'][value='41.50']"
    assert_select "input[name='transfer[date]'][value='#{date.iso8601}']"
  end

  test "the account pickers show each account's logo" do
    get new_transfer_url

    assert_select "[role=option][data-value='#{accounts(:depository).id}'] [data-select-logo]"
  end

  test "the drawer does not set a category on a transfer that takes none" do
    transfer = Transfer::Creator.new(
      family: families(:dylan_family), source_account_id: accounts(:depository).id,
      destination_account_id: accounts(:connected).id, date: Date.current, amount: 10
    ).create

    patch transfer_url(transfer), params: { transfer: { category_id: categories(:food_and_drink).id } }

    assert_nil transfer.outflow_transaction.reload.category_id
  end

  # --- w2-transfers transfer-tags-counterpart ---

  test "creates a transfer with tags on both sides" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id, to_account_id: accounts(:credit_card).id,
          date: Date.current, amount: 100, tag_ids: [ tags(:one).id ]
        }
      }
    end

    transfer = Transfer.order(:created_at).last
    assert_equal [ tags(:one).id ], transfer.outflow_transaction.tag_ids
    assert_equal [ tags(:one).id ], transfer.inflow_transaction.tag_ids
  end

  test "a failed create keeps the chosen tags" do
    post transfers_url, params: {
      transfer: {
        from_account_id: accounts(:depository).id, to_account_id: accounts(:depository).id,
        date: Date.current, amount: 100, tag_ids: [ tags(:one).id ]
      }
    }

    assert_response :unprocessable_entity
    assert_select "input[type=hidden][name='transfer[tag_ids][]'][value='#{tags(:one).id}']"
  end

  test "new keeps the tags another tab carried over" do
    get new_transfer_url(draft: { tag_ids: [ tags(:two).id ] })

    assert_response :success
    assert_select "input[type=hidden][name='transfer[tag_ids][]'][value='#{tags(:two).id}']"
  end

  test "the account pickers have a search box" do
    get new_transfer_url

    assert_select "[data-controller~=select][data-controller~=list-filter] input[type=search]", minimum: 2
  end
end
