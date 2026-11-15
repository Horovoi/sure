require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest, EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "creates with transaction details" do
    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      post transactions_url, params: {
        entry: {
          account_id: @entry.account_id,
          name: "New transaction",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "inflow",
          entryable_type: @entry.entryable_type,
          entryable_attributes: {
            tag_ids: [ Tag.first.id, Tag.second.id ],
            category_id: Category.first.id,
            merchant_id: Merchant.first.id
          }
        }
      }
    end

    created_entry = Entry.order(:created_at).last

    assert_redirected_to account_url(created_entry.account)
    assert_equal "Transaction created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "user can toggle one-time but cannot set a transfer kind" do
    patch transaction_url(@entry), params: { entry: { entryable_attributes: { id: @entry.entryable_id, kind: "one_time" } } }
    assert_equal "one_time", @entry.transaction.reload.kind

    patch transaction_url(@entry), params: { entry: { entryable_attributes: { id: @entry.entryable_id, kind: "funds_movement" } } }
    assert_equal "one_time", @entry.transaction.reload.kind
  end

  test "a transfer leg keeps its kind when the one-time toggle is sent" do
    transfer_leg = entries(:transfer_out)

    patch transaction_url(transfer_leg), params: { entry: { entryable_attributes: { id: transfer_leg.entryable_id, kind: "one_time" } } }

    assert_equal "cc_payment", transfer_leg.transaction.reload.kind
  end

  test "converting a transaction to a trade replaces the transaction so cash moves once" do
    investment = accounts(:investment)
    entry = create_transaction(account: investment, amount: 500, name: "Buy AAPL")

    assert_difference -> { investment.entries.where(entryable_type: "Trade").count } => 1,
                      -> { Transaction.where(id: entry.entryable_id).count } => -1 do
      post create_trade_from_transaction_transaction_url(entry.transaction), params: {
        security_id: securities(:aapl).id, qty: 5, investment_activity_label: "Buy"
      }
    end

    trade_entry = investment.entries.where(entryable_type: "Trade").order(:created_at).last
    assert_equal 500, trade_entry.amount
    assert_enqueued_with(job: SyncJob)
  end

  test "a transfer leg cannot be converted to a trade" do
    investment = accounts(:investment)
    inflow = create_transaction(account: investment, amount: -500)
    outflow = create_transaction(account: accounts(:depository), amount: 500)
    Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")

    assert_no_difference -> { Entry.count } do
      post create_trade_from_transaction_transaction_url(inflow.transaction), params: {
        security_id: securities(:aapl).id, qty: 5
      }
    end

    assert_equal I18n.t("transactions.convert_to_trade.errors.transfer_leg"), flash[:alert]
  end

  test "updates with transaction details" do
    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      patch transaction_url(@entry), params: {
        entry: {
          name: "Updated name",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "inflow",
          entryable_type: @entry.entryable_type,
          notes: "test notes",
          excluded: false,
          entryable_attributes: {
            id: @entry.entryable_id,
            tag_ids: [ Tag.first.id, Tag.second.id ],
            category_id: Category.first.id,
            merchant_id: Merchant.first.id
          }
        }
      }
    end

    @entry.reload

    assert_equal "Updated name", @entry.name
    assert_equal Date.current, @entry.date
    assert_equal "USD", @entry.currency
    assert_equal -100, @entry.amount
    assert_equal [ Tag.first.id, Tag.second.id ], @entry.entryable.tag_ids.sort
    assert_equal Category.first.id, @entry.entryable.category_id
    assert_equal Merchant.first.id, @entry.entryable.merchant_id
    assert_equal "test notes", @entry.notes
    assert_equal false, @entry.excluded

    assert_equal "Transaction updated", flash[:notice]
    assert_redirected_to account_url(@entry.account)
    assert_enqueued_with(job: SyncJob)
  end

  test "transaction count represents filtered total" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    3.times do
      create_transaction(account: account)
    end

    get transactions_url(per_page: 10)

    assert_dom "#total-transactions", count: 1, text: family.entries.transactions.size.to_s

    searchable_transaction = create_transaction(account: account, name: "Unique test name")

    get transactions_url(q: { search: searchable_transaction.name })

    # Only finds 1 transaction that matches filter
    assert_dom "#" + dom_id(searchable_transaction), count: 1
    assert_dom "#total-transactions", count: 1, text: "1"
  end

  test "can paginate" do
  family = families(:empty)
  sign_in users(:empty)

  # Clean up any existing entries to ensure clean test
  family.accounts.each { |account| account.entries.delete_all }

  account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

  # Create multiple transactions for pagination
  25.times do |i|
    create_transaction(
      account: account,
      name: "Transaction #{i + 1}",
      amount: 100 + i,  # Different amounts to prevent transfer matching
      date: Date.current - i.days  # Different dates
    )
  end

  total_transactions = family.entries.transactions.count
  assert_operator total_transactions, :>=, 20, "Should have at least 20 transactions for testing"

  # Test page 1 - should show limited transactions
  get transactions_url(page: 1, per_page: 10)
  assert_response :success

  page_1_count = css_select("turbo-frame[id^='entry_']").count
  assert_equal 10, page_1_count, "Page 1 should respect per_page limit"

  # Test page 2 - should show different transactions
  get transactions_url(page: 2, per_page: 10)
  assert_response :success

  page_2_count = css_select("turbo-frame[id^='entry_']").count
  assert_operator page_2_count, :>, 0, "Page 2 should show some transactions"
  assert_operator page_2_count, :<=, 10, "Page 2 should not exceed per_page limit"

  # Test Pagy overflow handling - should redirect or handle gracefully
  get transactions_url(page: 9999999, per_page: 10)

  # Either success (if Pagy shows last page) or redirect (if Pagy redirects)
  assert_includes [ 200, 302 ], response.status, "Pagy should handle overflow gracefully"

  if response.status == 302
    follow_redirect!
    assert_response :success
  end

  overflow_count = css_select("turbo-frame[id^='entry_']").count
  assert_operator overflow_count, :>, 0, "Overflow should show some transactions"
end

  test "calls Transaction::Search totals method with correct search parameters" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, amount: 100)

    search = Transaction::Search.new(family)
    totals = OpenStruct.new(
      count: 1,
      expense_money: Money.new(10000, "USD"),
      income_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: {}).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url
    assert_response :success
  end

  test "calls Transaction::Search totals method with filtered search parameters" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    category = family.categories.create! name: "Food", color: "#ff0000"

    create_transaction(account: account, amount: 100, category: category)

    search = Transaction::Search.new(family, filters: { "categories" => [ "Food" ], "types" => [ "expense" ] })
    totals = OpenStruct.new(
      count: 1,
      expense_money: Money.new(10000, "USD"),
      income_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: { "categories" => [ "Food" ], "types" => [ "expense" ] }).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url(q: { categories: [ "Food" ], types: [ "expense" ] })
    assert_response :success
  end

  test "clear_filters bypasses stored params restoration" do
    family = @user.family
    Session.order(:created_at).last.update!(
      prev_transaction_page_params: {
        q: { "categories" => [ "Food" ] },
        page: 3,
        per_page: 25
      }
    )

    search = Transaction::Search.new(family, filters: {})
    totals = OpenStruct.new(
      count: 0,
      expense_money: Money.new(0, family.currency),
      income_money: Money.new(0, family.currency)
    )

    Transaction::Search.expects(:new).with(family, filters: {}).returns(search)
    search.expects(:totals).returns(totals)

    get transactions_url(clear_filters: true, per_page: 50)

    assert_response :success
  end

  test "mark_as_recurring creates a manual recurring transaction" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Transaction marked as recurring", flash[:notice]

    recurring = family.recurring_transactions.last
    assert_equal true, recurring.manual, "Expected recurring transaction to be manual"
    assert_equal merchant.id, recurring.merchant_id
    assert_equal entry.currency, recurring.currency
    assert_equal entry.date.day, recurring.expected_day_of_month
  end

  test "mark_as_recurring shows alert if recurring transaction already exists" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Create existing recurring transaction
    family.recurring_transactions.create!(
      merchant: merchant,
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "A manual recurring transaction already exists for this pattern", flash[:alert]
  end

  test "mark_as_recurring handles validation errors gracefully" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Stub create_from_transaction to raise a validation error
    RecurringTransaction.expects(:create_from_transaction).raises(
      ActiveRecord::RecordInvalid.new(
        RecurringTransaction.new.tap { |rt| rt.errors.add(:base, "Test validation error") }
      )
    )

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Failed to create recurring transaction. Please check the transaction details and try again.", flash[:alert]
  end

  test "mark_as_recurring handles unexpected errors gracefully" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Stub create_from_transaction to raise an unexpected error
    RecurringTransaction.expects(:create_from_transaction).raises(StandardError.new("Unexpected error"))

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "An unexpected error occurred while creating the recurring transaction", flash[:alert]
  end

  test "collapsing a second section keeps the first one collapsed" do
    patch update_preferences_transactions_url, params: { preferences: { collapsed_sections: { upcoming: true } } }, as: :json
    patch update_preferences_transactions_url, params: { preferences: { collapsed_sections: { summary: true } } }, as: :json

    assert_response :success
    assert_equal({ "upcoming" => true, "summary" => true }, @user.reload.preferences["transactions_collapsed_sections"])
  end

  test "malformed preferences are a bad request, not an error" do
    patch update_preferences_transactions_url, params: { preferences: "nope" }, as: :json

    assert_response :bad_request
  end

  # --- DS pickers (w1-ds) ---

  test "new renders the DS pickers with the categories of the form's nature" do
    family = @user.family
    salary = family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")

    get new_transaction_url(nature: "inflow")

    assert_response :success
    assert_select "[data-controller=category-select][data-category-select-classification-value=income]"
    assert_select "[data-category-select-target=option][data-category-id='#{salary.id}']"
    assert_select "[data-category-select-target=option][data-category-id='#{categories(:food_and_drink).id}']", count: 0
    assert_select "[data-controller=merchant-select]"
    assert_select "[data-controller=tag-select]"
  end

  test "new shows recently used categories of the form's nature" do
    category = categories(:food_and_drink)
    category.update!(last_used_at: 1.minute.ago)

    get new_transaction_url

    assert_response :success
    assert_select "[data-category-select-target=recentSection] [data-category-id='#{category.id}']"
  end

  test "a failed create re-renders the income form for an income transaction" do
    post transactions_url, params: {
      entry: { account_id: accounts(:depository).id, name: "", date: "", amount: "", nature: "inflow", entryable_type: "Transaction" }
    }

    assert_response :unprocessable_entity
    assert_select "[data-category-select-classification-value=income]"
  end

  test "creating a transaction with a category records it as recently used" do
    category = categories(:food_and_drink)

    post transactions_url, params: {
      entry: {
        account_id: accounts(:depository).id, name: "Lunch", date: Date.current, amount: 12,
        currency: "USD", nature: "outflow", entryable_type: "Transaction",
        entryable_attributes: { category_id: category.id }
      }
    }

    assert_not_nil category.reload.last_used_at
  end

  test "changing the category in the drawer records it as recently used" do
    entry = entries(:transaction)
    category = categories(:subcategory)

    patch transaction_url(entry), params: {
      entry: { entryable_type: "Transaction", entryable_attributes: { id: entry.entryable_id, category_id: category.id } }
    }

    assert_not_nil category.reload.last_used_at
  end

  test "update_tags replaces the tag set and answers JSON" do
    entry = entries(:transaction)
    tag = @user.family.tags.first

    patch tags_transaction_url(entry), params: { tag_ids: [ tag.id ] }, as: :json

    assert_response :success
    assert_equal [ tag.id ], response.parsed_body["tag_ids"]
    assert_equal [ tag.id ], entry.transaction.reload.tag_ids
    assert entry.transaction.locked?(:tag_ids)
  end

  test "update_tags ignores tags of another family" do
    entry = entries(:transaction)
    foreign_tag = tags(:three)

    patch tags_transaction_url(entry), params: { tag_ids: [ foreign_tag.id ] }, as: :json

    assert_response :success
    assert_empty entry.transaction.reload.tag_ids
  end

  test "update_tags toggles one tag and streams the row summary and the picker row" do
    entry = entries(:transaction)
    tag = @user.family.tags.first
    entry.transaction.update!(tag_ids: [])

    patch tags_transaction_url(entry), params: { toggle_tag_id: tag.id }, as: :turbo_stream

    assert_response :success
    assert_includes entry.transaction.reload.tag_ids, tag.id
    assert_includes response.body, ActionView::RecordIdentifier.dom_id(entry.transaction, :tag_summary_desktop)
    assert_includes response.body, "#{ActionView::RecordIdentifier.dom_id(entry, :tag_option)}_#{tag.id}"

    patch tags_transaction_url(entry), params: { toggle_tag_id: tag.id }, as: :turbo_stream

    assert_not_includes entry.transaction.reload.tag_ids, tag.id
  end

  # --- Money field (w1-ds) ---

  test "the amount is a decimal text field and the currencies follow the family's list" do
    @user.family.update!(currency: "UAH", enabled_currencies: [ "UAH", "USD" ])

    get new_transaction_url(account_id: accounts(:depository).id)

    assert_response :success
    assert_select "input[type=text][name='entry[amount]'][inputmode=decimal]"
    options = css_select("select[name='entry[currency]'] option").map { |option| option["value"] }
    # The account's own currency is always offered on top of the family's list.
    assert_equal [ "UAH", "USD", accounts(:depository).currency ].uniq, options
  end

  test "the currency select keeps the money field's handler" do
    get new_transaction_url

    assert_select "select[name='entry[currency]'][data-action*='money-field#handleCurrencyChange']"
  end

  test "a blank amount in the drawer does not clear the saved amount" do
    entry = entries(:transaction)
    original = entry.amount

    patch transaction_url(entry), params: { entry: { amount: "", notes: "Kept" } }

    assert_equal original, entry.reload.amount
    assert_equal "Kept", entry.notes
  end
end
