require "test_helper"

class Account::ReconciliationIndicatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Indicator account", balance: 0, currency: "USD", accountable: Depository.new)
  end

  test "no indicator for an account without transactions" do
    assert_nil Account::ReconciliationIndicator.for(@account)
  end

  test "counts each status and needs attention while any is open" do
    create_transaction(account: @account)
    create_transaction(account: @account, reconciled_status: "cleared")
    create_transaction(account: @account, reconciled_status: "reconciled")
    create_transaction(account: @account, excluded: true) # left out

    indicator = Account::ReconciliationIndicator.for(@account)

    assert_equal [ 1, 1, 1 ], [ indicator.unreconciled_count, indicator.cleared_count, indicator.reconciled_count ]
    assert_equal 2, indicator.open_count
    assert_equal :needs_attention, indicator.status
  end

  test "matched when every transaction is reconciled" do
    2.times { create_transaction(account: @account, reconciled_status: "reconciled") }

    assert Account::ReconciliationIndicator.for(@account).matched?
  end

  test "a synced account gets none, and several accounts take one grouped count" do
    connected = accounts(:connected)
    create_transaction(account: @account)
    create_transaction(account: connected)

    indicators = nil
    assert_queries_count(2) do
      indicators = Account::ReconciliationIndicator.for_accounts([ @account, connected ])
    end

    assert_equal [ @account.id ], indicators.keys
  end
end
