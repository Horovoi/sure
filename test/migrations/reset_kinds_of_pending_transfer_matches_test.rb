require "test_helper"
# The stamp changes when the migration is re-stamped, so find it by name.
require Dir[Rails.root.join("db/migrate/*_reset_kinds_of_pending_transfer_matches.rb")].first

# Pending matches made before the kinds-on-confirm rule carry transfer kinds (and, into an
# investment account, the Investment Contributions category) set at match time. The
# migration puts those legs back to standard and leaves every confirmed transfer alone.
class ResetKindsOfPendingTransferMatchesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @category = ensure_investment_contributions_category(@family)
  end

  test "the legs of a pending match go back to standard" do
    transfer = old_style_pending(to: accounts(:credit_card), outflow_kind: "cc_payment")

    run_migration

    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
    assert Transfer.exists?(transfer.id), "the migration deletes nothing"
  end

  test "the auto-set contributions category is cleared from a pending match" do
    transfer = old_style_pending(to: accounts(:investment), outflow_kind: "investment_contribution", category: @category)

    run_migration

    outflow = transfer.outflow_transaction.reload
    assert_equal "standard", outflow.kind
    assert_nil outflow.category_id
  end

  test "another category on a pending match stays" do
    transfer = old_style_pending(to: accounts(:investment), outflow_kind: "investment_contribution", category: categories(:food_and_drink))

    run_migration

    assert_equal categories(:food_and_drink), transfer.outflow_transaction.reload.category
  end

  test "a one-time mark on a pending leg stays" do
    transfer = old_style_pending(to: accounts(:credit_card), outflow_kind: "one_time")

    run_migration

    assert_equal "one_time", transfer.outflow_transaction.reload.kind
  end

  test "confirmed transfers keep their kinds and category" do
    outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow = create_transaction(date: Date.current, account: accounts(:investment), amount: -500)
    transfer = Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")

    run_migration

    assert_equal "investment_contribution", transfer.outflow_transaction.reload.kind
    assert_equal @category, transfer.outflow_transaction.category
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
  end

  private
    # A pending match as the old matcher left it: kinds (and category) written at match time
    def old_style_pending(to:, outflow_kind:, category: nil)
      outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
      inflow = create_transaction(date: Date.current, account: to, amount: -500)
      transfer = Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)

      outflow.transaction.update_columns(kind: outflow_kind, category_id: category&.id)
      inflow.transaction.update_columns(kind: "funds_movement")
      transfer
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        ResetKindsOfPendingTransferMatches.new.up
      end
    end
end
