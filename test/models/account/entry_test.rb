require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @entry = entries :transaction
  end

  test "entry cannot be older than 10 years ago" do
    assert_raises ActiveRecord::RecordInvalid do
      @entry.update! date: 50.years.ago.to_date
    end
  end

  test "valuations cannot have more than one entry per day" do
    existing_valuation = entries :valuation

    new_valuation = Entry.new \
      entryable: Valuation.new(kind: "reconciliation"),
      account: existing_valuation.account,
      date: existing_valuation.date, # invalid
      currency: existing_valuation.currency,
      amount: existing_valuation.amount

    assert new_valuation.invalid?
  end

  test "triggers sync with correct start date when transaction is set to prior date" do
    prior_date = @entry.date - 1
    @entry.update! date: prior_date

    @entry.account.expects(:sync_later).with(window_start_date: prior_date)
    @entry.sync_account_later
  end

  test "triggers sync with correct start date when transaction is set to future date" do
    prior_date = @entry.date
    @entry.update! date: @entry.date + 1

    @entry.account.expects(:sync_later).with(window_start_date: prior_date)
    @entry.sync_account_later
  end

  test "triggers sync with correct start date when transaction deleted" do
    @entry.destroy!

    @entry.account.expects(:sync_later).with(window_start_date: nil)
    @entry.sync_account_later
  end

  test "can search entries" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    category = family.categories.first
    merchant = family.merchants.first

    create_transaction(account: account, name: "a transaction")
    create_transaction(account: account, name: "ignored")
    create_transaction(account: account, name: "third transaction", category: category, merchant: merchant)

    params = { search: "a" }

    assert_equal 2, family.entries.search(params).size

    params = { search: "%" }
    assert_equal 0, family.entries.search(params).size
  end

  test "visible scope only returns entries from visible accounts" do
    # Create transactions for all account types
    visible_transaction = create_transaction(account: accounts(:depository), name: "Visible transaction")
    invisible_transaction = create_transaction(account: accounts(:credit_card), name: "Invisible transaction")

    # Update account statuses
    accounts(:credit_card).disable!

    # Test the scope
    visible_entries = Entry.visible

    # Should include entry from active account
    assert_includes visible_entries, visible_transaction

    # Should not include entry from disabled account
    assert_not_includes visible_entries, invisible_transaction
  end

  # Pending scope tests
  test "pending scope returns pending transaction entries" do
    account = accounts(:depository)
    pending_entry = create_pending_entry(account: account, provider: "plaid")
    confirmed_entry = create_transaction(account: account, name: "Confirmed")

    results = Entry.pending

    assert_includes results, pending_entry
    assert_not_includes results, confirmed_entry
  end

  test "excluding_pending scope excludes pending entries" do
    account = accounts(:depository)
    pending_entry = create_pending_entry(account: account, provider: "plaid")
    confirmed_entry = create_transaction(account: account, name: "Confirmed")

    results = Entry.excluding_pending

    assert_not_includes results, pending_entry
    assert_includes results, confirmed_entry
  end

  test "excluding_pending includes Trade and Valuation entries" do
    account = accounts(:depository)
    valuation = create_valuation(account: account, name: "Valuation", date: Date.current)
    pending_entry = create_pending_entry(account: account, provider: "plaid")

    results = Entry.excluding_pending

    assert_includes results, valuation
    assert_not_includes results, pending_entry
  end

  test "stale_pending returns pending entries older than threshold" do
    account = accounts(:depository)
    stale_pending = create_pending_entry(account: account, provider: "plaid", date: 10.days.ago.to_date)
    recent_pending = create_pending_entry(account: account, provider: "plaid", date: 2.days.ago.to_date)

    results = Entry.stale_pending(days: 8)

    assert_includes results, stale_pending
    assert_not_includes results, recent_pending
  end

  test "pending scope works with multiple providers" do
    account = accounts(:depository)
    plaid_pending = create_pending_entry(account: account, provider: "plaid")
    lunchflow_pending = create_pending_entry(account: account, provider: "lunchflow")

    results = Entry.pending

    assert_includes results, plaid_pending
    assert_includes results, lunchflow_pending
  end

  private

    def create_pending_entry(account:, provider:, date: Date.current)
      transaction = Transaction.new(extra: { provider => { "pending" => true } })
      Entry.create!(
        account: account,
        name: "Pending transaction",
        date: date,
        currency: "USD",
        amount: 100,
        entryable: transaction
      )
    end
end
