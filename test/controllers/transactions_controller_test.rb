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
    totals = Transaction::Search::Totals.new(
      count: 0,
      expense_money: Money.new(0, family.currency),
      income_money: Money.new(0, family.currency),
      transfer_inflow_money: Money.new(0, family.currency),
      transfer_outflow_money: Money.new(0, family.currency)
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

  test "pagination does not duplicate or skip transactions with the same date and timestamp" do
    family = families(:empty)
    sign_in users(:empty)
    family.accounts.each { |account| account.entries.delete_all }

    account = family.accounts.create! name: "Same day", balance: 0, currency: "USD", accountable: Depository.new
    timestamp = 3.days.ago.change(usec: 0)

    entries = 13.times.map do |index|
      create_transaction(
        account: account,
        name: "Same day #{index + 1}",
        amount: 100 + index,
        date: timestamp.to_date,
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    expected_ids = Entry.where(id: entries.map(&:id)).reverse_chronological.pluck(:id).map(&:to_s)
    rendered_ids = -> { css_select("turbo-frame[id^='entry_']").map { |node| node["id"].delete_prefix("entry_") } }

    get transactions_url(page: 1, per_page: 10)
    assert_response :success
    page_1_ids = rendered_ids.call

    get transactions_url(page: 2, per_page: 10)
    assert_response :success
    page_2_ids = rendered_ids.call

    assert_equal expected_ids.first(10), page_1_ids
    assert_equal expected_ids.drop(10), page_2_ids
  end

  test "a blank amount or date in an update keeps the saved values" do
    original_amount = @entry.amount
    original_date = @entry.date

    patch transaction_url(@entry), params: { entry: { name: "Renamed with blanks", amount: "", date: "", nature: "outflow" } }

    @entry.reload
    assert_equal "Renamed with blanks", @entry.name
    assert_equal original_amount, @entry.amount
    assert_equal original_date, @entry.date
  end

  test "creating with a blank amount or date shows the form again" do
    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      post transactions_url, params: {
        entry: {
          account_id: @entry.account_id,
          name: "Blank amount",
          date: Date.current,
          currency: "USD",
          amount: "",
          nature: "outflow",
          entryable_type: "Transaction"
        }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      post transactions_url, params: {
        entry: {
          account_id: @entry.account_id,
          name: "Blank date",
          date: "",
          currency: "USD",
          amount: 10,
          nature: "outflow",
          entryable_type: "Transaction"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "a category-only edit skips the sync and asks for recurring detection" do
    assert_no_enqueued_jobs only: SyncJob do
      assert_enqueued_with(job: IdentifyRecurringTransactionsJob) do
        patch transaction_url(@entry), params: {
          entry: { entryable_attributes: { id: @entry.entryable_id, category_id: categories(:subscriptions).id } }
        }
      end
    end

    assert_equal categories(:subscriptions), @entry.reload.transaction.category
  end

  test "a notes-only edit neither syncs nor asks for recurring detection" do
    assert_no_enqueued_jobs only: [ SyncJob, IdentifyRecurringTransactionsJob ] do
      patch transaction_url(@entry), params: { entry: { notes: "Only a note" } }
    end

    assert_equal "Only a note", @entry.reload.notes
  end

  test "an amount edit syncs" do
    assert_enqueued_with(job: SyncJob) do
      patch transaction_url(@entry), params: { entry: { amount: @entry.amount + 5 } }
    end
  end

  test "a date edit syncs" do
    assert_enqueued_with(job: SyncJob) do
      patch transaction_url(@entry), params: { entry: { date: @entry.date - 3.days } }
    end
  end

  test "a descriptive edit together with an amount edit still syncs" do
    assert_enqueued_with(job: SyncJob) do
      patch transaction_url(@entry), params: { entry: { notes: "With amount", amount: @entry.amount + 1 } }
    end
  end

  test "a category-only edit changes the family's entries cache version" do
    before = Family.find(@entry.account.family_id).entries_cache_version

    travel 1.second do
      patch transaction_url(@entry), params: {
        entry: { entryable_attributes: { id: @entry.entryable_id, category_id: categories(:subscriptions).id } }
      }
    end

    assert_not_equal before, Family.find(@entry.account.family_id).entries_cache_version
  end

  def upcoming_test_row(name, manual: false, state: "pattern")
    families(:dylan_family).recurring_transactions.create!(
      name: name, amount: 42, currency: "USD", expected_day_of_month: 5.days.from_now.day,
      last_occurrence_date: 25.days.ago.to_date, next_expected_date: 5.days.from_now.to_date,
      status: "active", manual: manual, subscription_state: state, occurrence_count: 3
    )
  end

  test "upcoming lists only manual recurring rows and subscriptions" do
    upcoming_test_row("Upcoming manual rent", manual: true)
    upcoming_test_row("Upcoming streaming plan", state: "subscription")
    upcoming_test_row("Upcoming detected pattern")
    upcoming_test_row("Upcoming suggested pattern", state: "suggested")
    upcoming_test_row("Upcoming dismissed pattern", state: "dismissed")

    get transactions_url

    assert_response :success
    assert_includes response.body, "Upcoming manual rent"
    assert_includes response.body, "Upcoming streaming plan"
    assert_not_includes response.body, "Upcoming detected pattern"
    assert_not_includes response.body, "Upcoming suggested pattern"
    assert_not_includes response.body, "Upcoming dismissed pattern"
  end

  # A transaction in the empty family and a recurring row with its identity.
  def mark_test_setup(row_attributes = nil)
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Mark test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Mark Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)

    row = if row_attributes
      family.recurring_transactions.create!(
        { merchant: merchant, amount: 95, currency: "USD", expected_day_of_month: entry.date.day,
          last_occurrence_date: 1.month.ago.to_date, next_expected_date: 1.month.from_now.to_date,
          status: "active", occurrence_count: 3 }.merge(row_attributes)
      )
    end

    [ family, entry.transaction, row ]
  end

  test "mark_as_recurring converts a detected pattern in place" do
    family, transaction, row = mark_test_setup(manual: false, subscription_state: "pattern")

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal I18n.t("transactions.mark_as_recurring.converted"), flash[:notice]
    row.reload
    assert row.manual?
    assert_equal 100, row.amount
    assert row.pattern?
    assert_equal [ row.id ], family.recurring_transactions.pluck(:id)
  end

  test "mark_as_recurring converts a stale pattern and makes it active" do
    _family, transaction, row = mark_test_setup(manual: false, status: "inactive", inactive_reason: "stale")

    post mark_as_recurring_transaction_path(transaction)

    row.reload
    assert row.manual?
    assert row.active?
    assert_nil row.inactive_reason
  end

  test "mark_as_recurring keeps a suggestion a suggestion and makes it manual" do
    _family, transaction, row = mark_test_setup(manual: false, subscription_state: "suggested")

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    row.reload
    assert row.manual?
    assert row.suggested?
  end

  test "mark_as_recurring on a subscription shows an alert and changes nothing" do
    _family, transaction, row = mark_test_setup(manual: false, subscription_state: "subscription")

    assert_no_changes -> { row.reload.attributes.except("updated_at") } do
      assert_no_difference "RecurringTransaction.count" do
        post mark_as_recurring_transaction_path(transaction)
      end
    end

    assert_redirected_to transactions_path
    assert_equal I18n.t("transactions.mark_as_recurring.already_subscription"), flash[:alert]
  end

  test "mark_as_recurring shows an alert when a concurrent request took the identity" do
    _family, transaction, _row = mark_test_setup
    RecurringTransaction.expects(:create_from_transaction).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal I18n.t("transactions.mark_as_recurring.duplicate"), flash[:alert]
  end

  test "mark_as_recurring creates a row when the only row with the identity has a different amount" do
    family, transaction, _row = mark_test_setup(manual: false, amount: 40)

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_equal I18n.t("transactions.mark_as_recurring.success"), flash[:notice]
  end

  test "mark_as_subscription approves a suggestion in place" do
    _family, transaction, row = mark_test_setup(manual: false, subscription_state: "suggested")

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_subscription_transaction_path(transaction)
    end

    row.reload
    assert row.subscription?
    assert row.manual?
    assert_redirected_to edit_subscription_path(row)
    assert_equal I18n.t("transactions.mark_as_subscription.success"), flash[:notice]
  end

  test "mark_as_subscription confirms a manual row as a subscription" do
    _family, transaction, row = mark_test_setup(manual: true)

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_subscription_transaction_path(transaction)
    end

    assert row.reload.subscription?
    assert_redirected_to edit_subscription_path(row)
  end

  test "mark_as_subscription on a subscription shows an alert" do
    _family, transaction, _row = mark_test_setup(manual: false, subscription_state: "subscription")

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_subscription_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal I18n.t("transactions.mark_as_subscription.already_subscription"), flash[:alert]
  end

  test "mark_as_subscription creates a subscription when nothing has the identity" do
    family, transaction, _row = mark_test_setup

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_subscription_transaction_path(transaction)
    end

    row = family.recurring_transactions.last
    assert row.subscription?
    assert row.manual?
    assert_redirected_to edit_subscription_path(row)
  end

  # --- Exchange rate notes (w1-fx nearest-rate) ---

  test "transactions warns about a currency with no exchange rate and notes a stale one" do
    family = @user.family
    family.accounts.create!(name: "PLN cash", balance: 100, currency: "PLN", accountable: Depository.new)
    family.accounts.create!(name: "EUR cash", balance: 100, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: family.currency, date: 30.days.ago.to_date, rate: 1.1)

    get transactions_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", text: /No exchange rate from PLN to #{family.currency}/
    assert_select "[data-testid=stale-exchange-rates]", text: /EUR from #{Regexp.escape(I18n.l(30.days.ago.to_date, format: :long))}/
  end

  test "transactions shows no exchange rate note when every currency has a current rate" do
    get transactions_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", count: 0
    assert_select "[data-testid=stale-exchange-rates]", count: 0
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

  test "convert to trade preselects Buy for an outflow and Sell for an inflow" do
    investment = accounts(:investment)
    outflow = create_transaction(account: investment, amount: 500, name: "Bought shares")
    inflow = create_transaction(account: investment, amount: -500, name: "Sold shares")

    get convert_to_trade_transaction_url(outflow.entryable)
    assert_response :ok
    assert_select "select[name='investment_activity_label'] option[selected][value='Buy']"

    get convert_to_trade_transaction_url(inflow.entryable)
    assert_response :ok
    assert_select "select[name='investment_activity_label'] option[selected][value='Sell']"
  end

  # w2-transfers custom-exchange-rate
  test "creates a foreign-currency transaction with the user's rate" do
    account = accounts(:depository)

    post transactions_url, params: {
      entry: {
        account_id: account.id, name: "Hotel", date: Date.current, currency: "EUR", amount: 100, nature: "outflow",
        entryable_type: "Transaction", entryable_attributes: { exchange_rate: "1,08" }
      }
    }

    entry = account.entries.order(:created_at).last
    assert_equal "Hotel", entry.name
    assert_equal BigDecimal("1.08"), entry.transaction.exchange_rate
  end

  test "creates a foreign-currency transaction from the converted amount" do
    account = accounts(:depository)

    post transactions_url, params: {
      entry: {
        account_id: account.id, name: "Hotel", date: Date.current, currency: "EUR", amount: 100, nature: "outflow",
        entryable_type: "Transaction", converted_amount: "108.5"
      }
    }

    entry = account.entries.order(:created_at).last
    assert_equal BigDecimal("1.085"), entry.transaction.exchange_rate
  end

  test "a bad rate shows the form again" do
    account = accounts(:depository)

    assert_no_difference "Entry.count" do
      post transactions_url, params: {
        entry: {
          account_id: account.id, name: "Hotel", date: Date.current, currency: "EUR", amount: 100, nature: "outflow",
          entryable_type: "Transaction", entryable_attributes: { exchange_rate: "0" }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "changing the rate in the drawer syncs the account" do
    entry = create_transaction(account: accounts(:depository), currency: "EUR", amount: 50)

    assert_enqueued_with job: SyncJob do
      patch transaction_url(entry), params: { entry: { entryable_attributes: { id: entry.entryable_id, exchange_rate: "1.1" } } }
    end

    assert_equal BigDecimal("1.1"), entry.reload.transaction.exchange_rate
  end

  # w2-transfers transfer-hints
  test "a likely unmatched pair shows the Transfer? hint on the list" do
    outflow = create_transaction(account: accounts(:depository), amount: 321)
    create_transaction(account: accounts(:credit_card), amount: -321)

    get transactions_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)}" do
      assert_select "a[href='#{new_transaction_transfer_match_path(outflow)}']", text: /Transfer\?/
    end
  end

  test "the search form's stream request gets the summary and results streams" do
    get transactions_url(q: { search: "Starb" }), headers: {
      "Accept" => "text/vnd.turbo-stream.html, text/html", "Turbo-Frame" => "transactions_results"
    }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, %(target="transactions_summary")
  end

  test "a stream request that is not the search (a redirect after a posted form) gets the page and its flash" do
    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entries(:transaction).id ], notes: "Bulk" } },
                                       headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    follow_redirect!(headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" })

    assert_equal "text/html", response.media_type
    assert_includes response.body, I18n.t("transactions.bulk_updates.create.success", count: 1)
  end

  test "a list of transfers only shows inflow and outflow totals" do
    family = @user.family
    checking = family.accounts.create!(name: "Totals checking", balance: 0, currency: family.currency, accountable: Depository.new)
    savings = family.accounts.create!(name: "Totals savings", balance: 0, currency: family.currency, accountable: Depository.new)
    create_transfer(from_account: checking, to_account: savings, amount: 250, currency: family.currency)

    # Only the new accounts: the fixtures' own transfer would add to the totals
    get transactions_url(q: { types: [ "transfer" ], account_ids: [ checking.id, savings.id ] })

    assert_response :success
    assert_select "#total-income", text: /250/
    assert_select "#total-expense", text: /250/
    assert_select "p", text: "Inflow"
    assert_select "p", text: "Outflow"
  end

  # --- w2-transfers transfer-form-fixes ---

  test "new takes the values another tab carried over" do
    tag = tags(:one)
    date = 4.days.ago.to_date

    get new_transaction_url(nature: "inflow", draft: {
      name: "Carried", amount: "12,5", date: date.iso8601, account_id: accounts(:depository).id, tag_ids: [ tag.id ]
    })

    assert_response :success
    assert_select "input[name='entry[name]'][value='Carried']"
    assert_select "input[name='entry[amount]'][value='12.50']"
    assert_select "input[name='entry[date]'][value='#{date.iso8601}']"
    assert_select "select[name='entry[account_id]'] option[selected][value='#{accounts(:depository).id}']"
    assert_select "input[type=hidden][name='entry[entryable_attributes][tag_ids][]'][value='#{tag.id}']"
  end

  test "update drops a category sent for a confirmed transfer's inflow leg" do
    outflow = Transaction.new
    accounts(:depository).entries.create!(name: "Contribution", amount: 500, currency: "USD", date: Date.current, entryable: outflow)
    inflow = Transaction.new
    inflow_entry = accounts(:investment).entries.create!(name: "Contribution", amount: -500, currency: "USD", date: Date.current, entryable: inflow)
    Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    patch transaction_url(inflow_entry), params: {
      entry: { notes: "Monthly savings", entryable_type: "Transaction", entryable_attributes: { id: inflow.id, category_id: categories(:food_and_drink).id } }
    }

    assert_nil inflow.reload.category_id
    assert_equal "Monthly savings", inflow_entry.reload.notes
  end

  test "the drawer shows a confirmed transfer's inflow leg with the outflow's category, disabled" do
    outflow = Transaction.new(category: categories(:food_and_drink))
    accounts(:depository).entries.create!(name: "Contribution", amount: 500, currency: "USD", date: Date.current, entryable: outflow)
    inflow = Transaction.new
    inflow_entry = accounts(:investment).entries.create!(name: "Contribution", amount: -500, currency: "USD", date: Date.current, entryable: inflow)
    Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    get transaction_url(inflow_entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_select "button[disabled]", text: /#{categories(:food_and_drink).name}/
    assert_select "input[type=hidden][name='entry[entryable_attributes][category_id]'][disabled]"
    assert_includes response.body, I18n.t("transactions.show.category_set_on_outflow")
  end

  test "an investment contribution's outflow row has a category menu and its inflow row a read-only badge" do
    outflow = Transaction.new(category: categories(:food_and_drink))
    accounts(:depository).entries.create!(name: "Contribution out", amount: 500, currency: "USD", date: Date.current, entryable: outflow)
    inflow = Transaction.new
    accounts(:investment).entries.create!(name: "Contribution in", amount: -500, currency: "USD", date: Date.current, entryable: inflow)
    Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    get transactions_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(outflow, :category_menu_desktop)} turbo-frame#category_dropdown"
    assert_select "##{ActionView::RecordIdentifier.dom_id(inflow, :category_menu_desktop)} turbo-frame#category_dropdown", count: 0
  end

  # --- w2-transfers transfer-tags-counterpart ---

  test "transfer rows name the counterpart account without a lookup per row" do
    3.times do |i|
      Transfer::Creator.new(
        family: families(:dylan_family), source_account_id: accounts(:depository).id,
        destination_account_id: accounts(:connected).id, date: Date.current - i, amount: 10 + i
      ).create
    end

    # A lazy belongs_to or has_one load ends in LIMIT; a preload does not
    lazy_leg_lookup = /"transactions"\."id" = \$1 LIMIT|"entries"\."entryable_id" = \$1|"accounts"\."id" = \$1 LIMIT|"transfers"\."(inflow|outflow)_transaction_id" = \$1/
    assert_no_queries_match(lazy_leg_lookup) do
      get transactions_url
    end

    assert_response :success
    assert_includes response.body, "#{accounts(:depository).name} → #{accounts(:connected).name}"
  end

  # --- w2-transfers default-account ---

  test "the new-transaction form preselects the default account" do
    users(:family_admin).update!(default_account: accounts(:depository))

    get new_transaction_url

    assert_select "select[name='entry[account_id]'] option[selected][value='#{accounts(:depository).id}']"
  end

  test "a disabled default account is not preselected" do
    users(:family_admin).update!(default_account: accounts(:depository))
    accounts(:depository).update_columns(status: "disabled") # skips the callback that clears it

    get new_transaction_url

    assert_select "select[name='entry[account_id]'] option[selected]", count: 0
  end

  test "an account the form was opened for wins over the default" do
    users(:family_admin).update!(default_account: accounts(:depository))

    get new_transaction_url(account_id: accounts(:credit_card).id)

    assert_select "input[type=hidden][name='entry[account_id]'][value='#{accounts(:credit_card).id}']"
  end

  # --- Duplicate (w2-rules): the selection bars' copy button ---

  test "new with duplicate_entry_id fills the form from the transaction" do
    @entry.update!(notes: "Weekly coffee")
    @entry.transaction.update!(tags: [ tags(:one) ])

    get new_transaction_url(duplicate_entry_id: @entry.id)

    assert_response :success
    assert_select "input[name='entry[name]'][value=?]", @entry.name
    assert_select "input[name='entry[amount]']" do |elements|
      assert_equal @entry.amount.abs.to_d, elements.first["value"].to_d
    end
    assert_select "input[type=hidden][name='entry[account_id]'][value=?]", @entry.account_id
    assert_select "input[name='entry[nature]'][value=outflow]"
    assert_select "input[type=hidden][name='entry[entryable_attributes][category_id]'][value=?]", @entry.transaction.category_id
    assert_select "input[type=hidden][name='entry[entryable_attributes][merchant_id]'][value=?]", @entry.transaction.merchant_id
    assert_select "input[type=hidden][name='entry[entryable_attributes][tag_ids][]'][value=?]", tags(:one).id
    assert_select "textarea[name='entry[notes]']", text: "Weekly coffee"
    # Dated today, not on the source's date
    assert_select "input[name='entry[date]'][value=?]", Date.current.to_s
  end

  test "duplicating an income opens the income form with its category" do
    salary = @user.family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")
    income = create_transaction(account: accounts(:depository), name: "Pay", amount: -500, category: salary)

    get new_transaction_url(duplicate_entry_id: income.id)

    assert_response :success
    assert_select "input[name='entry[nature]'][value=inflow]"
    assert_select "input[type=hidden][name='entry[entryable_attributes][category_id]'][value=?]", salary.id
  end

  test "new with an unknown duplicate_entry_id renders an empty form" do
    get new_transaction_url(duplicate_entry_id: "not-an-id")

    assert_response :success
    assert_select "input[name='entry[name]']" do |elements|
      assert_nil elements.first["value"]
    end
  end

  test "new with another family's duplicate_entry_id does not fill the form" do
    other_account = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    other_entry = create_transaction(account: other_account, name: "Should not leak", amount: 50)

    get new_transaction_url(duplicate_entry_id: other_entry.id)

    assert_response :success
    assert_not_includes response.body, "Should not leak"
  end

  test "new with a valuation id does not fill the form" do
    valuation = entries(:valuation)

    get new_transaction_url(duplicate_entry_id: valuation.id)

    assert_response :success
    assert_select "input[name='entry[name]']" do |elements|
      assert_nil elements.first["value"]
    end
  end

  test "the transactions selection bar has a hidden duplicate link" do
    get transactions_url

    assert_select "#entry-selection-bar a[data-bulk-select-target=duplicateLink].hidden[href=?]", new_transaction_path
  end

  # --- Name suggestions (w2-rules): the new form's name autocomplete ---

  test "name_suggestions returns past names with their usual category" do
    get name_suggestions_transactions_url(q: "Starb", for_id: "entry_name", format: :turbo_stream)

    assert_response :success
    assert_includes response.body, "Starbucks"
    assert_includes response.body, %(data-category-id="#{categories(:food_and_drink).id}")
  end

  test "name_suggestions reads only the family's transactions" do
    other_account = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    create_transaction(account: other_account, name: "Starbucks of another family", amount: 5)

    get name_suggestions_transactions_url(q: "Starb", for_id: "entry_name", format: :turbo_stream)

    assert_response :success
    assert_not_includes response.body, "Starbucks of another family"
  end

  test "name_suggestions for an income form offers no expense category" do
    get name_suggestions_transactions_url(q: "Starb", nature: "inflow", for_id: "entry_name", format: :turbo_stream)

    assert_response :success
    assert_includes response.body, "Starbucks"
    assert_not_includes response.body, %(data-category-id="#{categories(:food_and_drink).id}")
  end

  test "the new form's name field is an autocomplete that asks name_suggestions" do
    get new_transaction_url(nature: "inflow")

    assert_response :success
    assert_select "form[data-controller~=category-suggestion]"
    assert_select "input#entry_name[role=combobox][required]"
    assert_includes response.body, CGI.escapeHTML(name_suggestions_transactions_path(nature: "inflow"))
  end

  # --- w3-toolstrx filter-options ---------------------------------------------------------------------------

  test "index names the account on an account_ids filter chip" do
    account = @entry.account

    get transactions_url(q: { account_ids: [ account.id ] })

    assert_response :success
    assert_select "#transaction-search-filters li p", text: account.name, count: 1
    assert_select "#transaction-search-filters li p", text: account.id, count: 0
  end

  test "index renders a blank account filter value without failing" do
    get transactions_url(q: { account_ids: [ "" ], accounts: [ "" ] })

    assert_response :success
  end

  test "index shows No merchant and Untagged as options and as chips" do
    get transactions_url(q: { merchants: [ Merchant::NO_MERCHANT_FILTER_VALUE ], tags: [ Tag::UNTAGGED_FILTER_VALUE ] })

    assert_response :success
    assert_select "#transaction-search-filters li p", text: "No merchant", count: 1
    assert_select "#transaction-search-filters li p", text: "Untagged", count: 1
    assert_select "input[type=checkbox][name='q[merchants][]'][value='#{Merchant::NO_MERCHANT_FILTER_VALUE}'][checked]"
    assert_select "input[type=checkbox][name='q[tags][]'][value='#{Tag::UNTAGGED_FILTER_VALUE}'][checked]"
  end
end
