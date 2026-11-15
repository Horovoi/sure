require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @entry = entries :transaction
  end

  test "an opening anchor cannot be destroyed on its own, but goes with its account" do
    account = families(:empty).accounts.create!(name: "Cash", balance: 100, currency: "USD", accountable: Depository.new)
    anchor = account.entries.create!(date: 1.year.ago.to_date, name: "Opening", amount: 100, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))

    assert_not anchor.destroy
    assert_includes anchor.errors.full_messages, I18n.t("activerecord.errors.models.entry.attributes.base.anchor_not_deletable")
    assert Entry.exists?(anchor.id)

    account.destroy!
    assert_not Entry.exists?(anchor.id)
  end

  test "a reconciliation can be destroyed" do
    account = families(:empty).accounts.create!(name: "Cash", balance: 100, currency: "USD", accountable: Depository.new)
    reconciliation = account.entries.create!(date: 1.day.ago.to_date, name: "Value", amount: 100, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))

    assert reconciliation.destroy
  end

  test "an account has at most one anchor of each kind" do
    account = families(:empty).accounts.create!(name: "Cash", balance: 100, currency: "USD", accountable: Depository.new)
    account.entries.create!(date: 1.year.ago.to_date, name: "Opening", amount: 100, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))

    duplicate = account.entries.build(date: 2.years.ago.to_date, name: "Opening", amount: 50, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))

    assert_not duplicate.valid?
    assert_includes duplicate.errors.full_messages, I18n.t("activerecord.errors.models.entry.attributes.base.duplicate_anchor")
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

    test "chronological order breaks a date and created_at tie by id" do
      account = families(:empty).accounts.create!(name: "Cash", balance: 100, currency: "USD", accountable: Depository.new)
      created_at = Time.current.change(usec: 0)
      entries = 3.times.map do |i|
        create_transaction(account: account, name: "Tie #{i}", date: Date.current, created_at: created_at)
      end
      ids = entries.map(&:id).sort

      assert_equal ids, account.entries.where(id: ids).chronological.pluck(:id)
      assert_equal ids.reverse, account.entries.where(id: ids).reverse_chronological.pluck(:id)
    end

    test "bulk_update! gives a balance update only the entry fields" do
      account = accounts(:depository)
      transaction_entry = create_transaction(account: account, name: "Bulk transaction")
      valuation_entry = create_valuation(account: account, date: 3.days.ago.to_date)
      category = categories(:food_and_drink)

      updated = Entry.where(id: [ transaction_entry.id, valuation_entry.id ])
                     .bulk_update!({ notes: "Bulk note", category_id: category.id })

      assert_equal 2, updated
      assert_equal "Bulk note", valuation_entry.reload.notes
      assert_equal "Bulk note", transaction_entry.reload.notes
      assert_equal category, transaction_entry.transaction.category
    end

    test "bulk_update! with only a category leaves a balance update untouched" do
      account = accounts(:depository)
      transaction_entry = create_transaction(account: account, name: "Category only")
      valuation_entry = create_valuation(account: account, date: 6.days.ago.to_date)
      category = categories(:food_and_drink)

      assert_no_changes -> { valuation_entry.reload.updated_at } do
        Entry.where(id: [ transaction_entry.id, valuation_entry.id ]).bulk_update!({ category_id: category.id })
      end

      assert_equal category, transaction_entry.reload.transaction.category
    end
end
