require "test_helper"

class Balance::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include BalanceTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Test",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "syncs balances" do
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    expected_balances = [
      Balance.new(
        date: 1.day.ago.to_date,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 500,
        start_non_cash_balance: 0,
        cash_inflows: 500,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: Date.current,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 1000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      )
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(expected_balances)

    assert_difference "@account.balances.count", 2 do
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    assert_balance_fields_persisted(expected_balances)
  end

  test "purges stale balances outside calculated range" do
    # Create existing balances that will be stale
    stale_old = create_balance(account: @account, date: 5.days.ago.to_date, balance: 5000)
    stale_future = create_balance(account: @account, date: 2.days.from_now.to_date, balance: 15000)

    # Calculator will return balances for only these dates
    expected_balances = [
      Balance.new(
        date: 2.days.ago.to_date,
        balance: 10000,
        cash_balance: 10000,
        currency: "USD",
        start_cash_balance: 10000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: 1.day.ago.to_date,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 10000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 9000,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: Date.current,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 1000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      )
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(expected_balances)
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    # Should end up with 3 balances (stale ones deleted, new ones created)
    assert_difference "@account.balances.count", 1 do
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    # Verify stale balances were deleted
    assert_nil @account.balances.find_by(id: stale_old.id)
    assert_nil @account.balances.find_by(id: stale_future.id)

    # Verify expected balances were persisted
    assert_balance_fields_persisted(expected_balances)
  end

  test "account balance is today's balance, not a future-dated one" do
    account = families(:empty).accounts.create!(name: "Cash", balance: 0, cash_balance: 0, currency: "USD", accountable: Depository.new)
    account.entries.create!(date: 1.month.ago.to_date, name: "Opening", amount: 1000, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))
    create_transaction(account: account, date: 5.days.from_now.to_date, amount: 100)

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    assert_equal 1000, account.reload.balance
    assert_equal 900, account.balances.order(date: :desc).first.end_balance
  end

  test "purges every stored balance when nothing is calculated" do
    stale = create_balance(account: @account, date: 5.days.ago.to_date, balance: 5000)

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns([])
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    Balance::Materializer.new(@account, strategy: :forward).materialize_balances

    assert_nil @account.balances.find_by(id: stale.id)
    assert_equal 0, @account.reload.balance
  end


  test "persists calculated balance data in batches" do
    account = families(:empty).accounts.create!(name: "Batches", balance: 0, cash_balance: 0, currency: "USD", accountable: Depository.new)
    account.entries.create!(name: "Opening", date: 4.days.ago.to_date, amount: 500, currency: "USD",
                            entryable: Valuation.new(kind: "opening_anchor"))

    calculated = Balance::ForwardCalculator.new(account).calculate
    assert calculated.all? { |b| b.is_a?(Balance::BalanceData) }

    stub_const(Balance::Materializer, :PERSIST_BATCH_SIZE, 2) do
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
    end

    assert_equal calculated.size, account.balances.count
    assert_equal 500, account.balances.find_by(date: Date.current).balance
  end

  private

    def assert_balance_fields_persisted(expected_balances)
      expected_balances.each do |expected|
        persisted = @account.balances.find_by(date: expected.date)
        assert_not_nil persisted, "Balance for #{expected.date} should be persisted"

        # Check all balance component fields
        assert_equal expected.balance, persisted.balance
        assert_equal expected.cash_balance, persisted.cash_balance
        assert_equal expected.start_cash_balance, persisted.start_cash_balance
        assert_equal expected.start_non_cash_balance, persisted.start_non_cash_balance
        assert_equal expected.cash_inflows, persisted.cash_inflows
        assert_equal expected.cash_outflows, persisted.cash_outflows
        assert_equal expected.non_cash_inflows, persisted.non_cash_inflows
        assert_equal expected.non_cash_outflows, persisted.non_cash_outflows
        assert_equal expected.net_market_flows, persisted.net_market_flows
        assert_equal expected.cash_adjustments, persisted.cash_adjustments
        assert_equal expected.non_cash_adjustments, persisted.non_cash_adjustments
        assert_equal expected.flows_factor, persisted.flows_factor
      end
    end
end
