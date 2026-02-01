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

  private

    def create_pending_transaction(account:, name:, provider:, date: Date.current)
      transaction = Transaction.new(extra: { provider => { "pending" => true } })
      Entry.create!(
        account: account,
        name: name,
        date: date,
        currency: "USD",
        amount: 100,
        entryable: transaction
      )
    end
end
