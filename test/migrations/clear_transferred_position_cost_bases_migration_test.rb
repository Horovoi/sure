require "test_helper"
# The stamp changes when the migration is re-stamped, so find it by name.
require Dir[Rails.root.join("db/migrate/*_clear_transferred_position_cost_bases.rb")].first

# The migration clears figures the app worked out for positions whose cost it cannot know,
# and it cannot be undone. Which positions those are is decided at runtime by
# Holding#avg_cost and the calculators, so each case checks the runtime first.
class ClearTransferredPositionCostBasesMigrationTest < ActiveSupport::TestCase
  setup do
    @holding = holdings(:one)
    @account = @holding.account
    # Everything already there is an ordinary purchase; the transfer under test is the only one
    @account.trades.update_all(investment_activity_label: "Buy")
    # Empty, so avg_cost answers from the computation rather than a stored figure
    @holding.update_columns(cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)
  end

  test "a position transferred in loses the figure the app worked out" do
    transfer(qty: 5)

    assert_nil @holding.reload.avg_cost, "the runtime already treats this position as unknown"
    store_basis(source: "calculated")

    run_migration

    @holding.reload
    assert_nil @holding.cost_basis
    assert_nil @holding.cost_basis_source
  end

  test "a source-less figure on a position transferred in is cleared too" do
    transfer(qty: 5)
    store_basis(source: nil)

    run_migration

    assert_nil @holding.reload.cost_basis
  end

  # Shares sent elsewhere leave the remaining ones with the cost they were bought at
  test "a position transferred out keeps it" do
    transfer(qty: -5)

    assert_not_nil @holding.reload.avg_cost, "the runtime keeps the basis after a transfer out"
    store_basis(source: "calculated")

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d
  end

  test "a figure the user set stays" do
    transfer(qty: 5)
    @holding.update_columns(cost_basis: 100, cost_basis_source: "manual", cost_basis_locked: true)

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d
  end

  test "a provider figure stays" do
    transfer(qty: 5)
    store_basis(source: "provider")

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d
  end

  test "a row dated before the transfer keeps its figure" do
    earlier = holdings(:two)
    assert_operator earlier.date, :<, @holding.date
    transfer(qty: 5, date: @holding.date)
    earlier.update_columns(cost_basis: 100, cost_basis_source: "calculated", cost_basis_locked: false)

    run_migration

    assert_equal 100, earlier.reload.cost_basis.to_d
  end

  test "a position with no transfer keeps its figure" do
    store_basis(source: "calculated")

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d
  end

  private
    def store_basis(source:)
      @holding.update_columns(cost_basis: 100, cost_basis_source: source)
    end

    def transfer(qty:, date: @holding.date - 1)
      @account.entries.create!(
        date: date,
        name: "Moved #{qty} units",
        amount: -100,
        currency: @holding.currency,
        entryable: Trade.new(
          security: @holding.security,
          qty: qty,
          price: 100,
          currency: @holding.currency,
          investment_activity_label: Trade::TRANSFER_LABEL
        )
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        ClearTransferredPositionCostBases.new.up
      end
    end
end
