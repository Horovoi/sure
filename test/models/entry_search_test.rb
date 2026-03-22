require "test_helper"

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family = @account.family
  end

  test "status filter pending returns only pending transactions" do
    confirmed_entry = create_transaction(account: @account, name: "Confirmed")
    pending_entry = create_pending_transaction(account: @account, name: "Pending", provider: "plaid")

    results = Entry.search(status: [ "pending" ])

    assert_includes results, pending_entry
    assert_not_includes results, confirmed_entry
  end

  test "status filter confirmed excludes pending transactions" do
    confirmed_entry = create_transaction(account: @account, name: "Confirmed")
    pending_entry = create_pending_transaction(account: @account, name: "Pending", provider: "plaid")

    results = Entry.search(status: [ "confirmed" ])

    assert_includes results, confirmed_entry
    assert_not_includes results, pending_entry
  end

  test "status filter with both statuses returns all entries" do
    confirmed_entry = create_transaction(account: @account, name: "Confirmed")
    pending_entry = create_pending_transaction(account: @account, name: "Pending", provider: "plaid")

    results = Entry.search(status: %w[pending confirmed])

    assert_includes results, confirmed_entry
    assert_includes results, pending_entry
  end

  test "status filter pending works with non-plaid providers" do
    confirmed_entry = create_transaction(account: @account, name: "Confirmed")
    lunchflow_pending = create_pending_transaction(account: @account, name: "Lunchflow pending", provider: "lunchflow")

    results = Entry.search(status: [ "pending" ])

    assert_includes results, lunchflow_pending
    assert_not_includes results, confirmed_entry
  end

  test "non-transaction entries are treated as confirmed" do
    valuation = create_valuation(account: @account, name: "Valuation", date: Date.current)
    pending_entry = create_pending_transaction(account: @account, name: "Pending", provider: "plaid")

    # Valuation should appear in confirmed results
    confirmed_results = Entry.search(status: [ "confirmed" ])
    assert_includes confirmed_results, valuation

    # Valuation should NOT appear in pending results
    pending_results = Entry.search(status: [ "pending" ])
    assert_not_includes pending_results, valuation
    assert_includes pending_results, pending_entry
  end

  test "mixed income and trade type filter returns both transaction and trade entries" do
    income_entry = create_transaction(account: @account, name: "Salary", amount: -150)
    trade_entry = create_trade(securities(:aapl), account: accounts(:investment), qty: 2, date: Date.current)
    expense_entry = create_transaction(account: @account, name: "Groceries", amount: 40)
    valuation_entry = create_valuation(account: @account, name: "Snapshot", date: Date.current - 1.day)

    results = Entry.search(types: %w[income trade])

    assert_includes results, income_entry
    assert_includes results, trade_entry
    assert_not_includes results, expense_entry
    assert_not_includes results, valuation_entry
  end

  test "mixed balance update and expense type filter returns both valuation and expense entries" do
    valuation_entry = create_valuation(account: @account, name: "Snapshot", date: Date.current - 1.day)
    expense_entry = create_transaction(account: @account, name: "Coffee", amount: 25)
    income_entry = create_transaction(account: @account, name: "Paycheck", amount: -200)

    results = Entry.search(types: %w[balance_update expense])

    assert_includes results, valuation_entry
    assert_includes results, expense_entry
    assert_not_includes results, income_entry
  end

  test "selecting all five types behaves like no type filter" do
    expense_entry = create_transaction(account: @account, name: "Coffee", amount: 25)
    income_entry = create_transaction(account: @account, name: "Paycheck", amount: -200)
    transfer_entry = create_transaction(account: @account, name: "Transfer", amount: 50, kind: "funds_movement")
    valuation_entry = create_valuation(account: @account, name: "Snapshot", date: Date.current - 1.day)
    trade_entry = create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current)

    scoped_ids = [ expense_entry, income_entry, transfer_entry, valuation_entry, trade_entry ].map(&:id)

    results = Entry.search(types: %w[income expense transfer balance_update trade]).where(id: scoped_ids)

    assert_equal scoped_ids.sort, results.ids.sort
  end

  test "category, merchant, and tag filters only match transaction entries" do
    matching_entry = create_transaction(
      account: @account,
      name: "Matched purchase",
      amount: 60,
      category: categories(:food_and_drink),
      merchant: merchants(:amazon),
      tags: [ tags(:one) ]
    )
    trade_entry = create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current)
    valuation_entry = create_valuation(account: @account, name: "Snapshot", date: Date.current - 1.day)

    assert_equal [ matching_entry.id ], Entry.search(categories: [ categories(:food_and_drink).name ]).where(id: [ matching_entry.id, trade_entry.id, valuation_entry.id ]).ids
    assert_equal [ matching_entry.id ], Entry.search(merchants: [ merchants(:amazon).name ]).where(id: [ matching_entry.id, trade_entry.id, valuation_entry.id ]).ids
    assert_equal [ matching_entry.id ], Entry.search(tags: [ tags(:one).name ]).where(id: [ matching_entry.id, trade_entry.id, valuation_entry.id ]).ids
  end

  test "transaction-specific filters compose with status date and search" do
    matching_entry = create_pending_transaction(
      account: @account,
      name: "Composable lunch",
      provider: "plaid",
      date: Date.current,
      amount: 42,
      category: categories(:food_and_drink)
    )
    create_transaction(account: @account, name: "Composable lunch old", amount: 42, date: 2.days.ago, category: categories(:food_and_drink))
    create_transaction(account: @account, name: "Composable lunch income", amount: -42, date: Date.current, category: categories(:food_and_drink))

    results = Entry.search(
      search: "Composable lunch",
      start_date: Date.current.to_s,
      end_date: Date.current.to_s,
      status: [ "pending" ],
      types: [ "expense" ],
      categories: [ categories(:food_and_drink).name ]
    )

    assert_includes results, matching_entry
    assert_equal [ matching_entry.id ], results.where(id: Entry.where("entries.name LIKE ?", "Composable lunch%").select(:id)).ids
  end

  private

    def create_pending_transaction(account:, name:, provider:, date: Date.current, amount: 100, **transaction_attributes)
      transaction = Transaction.new(transaction_attributes.merge(extra: { provider => { "pending" => true } }))
      Entry.create!(
        account: account,
        name: name,
        date: date,
        currency: "USD",
        amount: amount,
        entryable: transaction
      )
    end
end
