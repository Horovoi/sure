require "test_helper"

class Holding::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    @aapl = securities(:aapl)
  end

  test "syncs holdings" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    # Should have yesterday's and today's holdings
    assert_difference "@account.holdings.count", 2 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  test "purges stale holdings for unlinked accounts" do
    # Since the account has no entries, there should be no holdings
    Holding.create!(account: @account, security: @aapl, qty: 1, price: 100, amount: 100, currency: "USD", date: Date.current)

    assert_difference "Holding.count", -1 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  test "a manual cost basis is carried forward to rows created on later days" do
    create_trade(@aapl, account: @account, qty: 1, date: 1.day.ago.to_date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    # The user set the cost basis yesterday, when yesterday's row was the newest one
    @account.holdings.where(security: @aapl, date: Date.current).delete_all
    yesterday = @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date)
    yesterday.set_manual_cost_basis!(BigDecimal("100"))

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    today = @account.holdings.find_by!(security: @aapl, date: Date.current)
    assert_equal BigDecimal("100"), today.cost_basis
    assert_equal "manual", today.cost_basis_source
    assert today.cost_basis_locked?
    assert_equal today, @account.current_holdings.find_by(security: @aapl)
  end

  test "setting a manual cost basis applies to the later rows of the position, unlocking clears it everywhere" do
    create_trade(@aapl, account: @account, qty: 1, date: 1.day.ago.to_date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    yesterday = @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date)
    yesterday.set_manual_cost_basis!(BigDecimal("100"))

    today = @account.holdings.find_by!(security: @aapl, date: Date.current)
    assert today.cost_basis_locked?
    assert_equal BigDecimal("100"), today.cost_basis

    today.unlock_cost_basis!
    assert_not yesterday.reload.cost_basis_locked?

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    today.reload
    assert_equal "calculated", today.cost_basis_source
    assert_equal BigDecimal("214"), today.cost_basis
  end

  test "preserves provider cost_basis when trade-derived cost_basis is nil" do
    # Simulate a provider-imported holding with cost_basis (e.g., from a provider)
    # This is the realistic scenario: linked account with provider holdings but no trades
    provider_cost_basis = BigDecimal("150.00")
    holding = Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: provider_cost_basis
    )

    # Use :reverse strategy (what linked accounts use) - doesn't purge holdings
    # The AAPL holding has no trades, so computed cost_basis is nil
    # The materializer should preserve the provider cost_basis, not overwrite with nil
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding.reload
    assert_equal provider_cost_basis, holding.cost_basis,
      "Provider cost_basis should be preserved when no trades exist for this security"
  end

  test "updates cost_basis when trade-derived cost_basis is available" do
    # Create a holding with provider cost_basis
    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: BigDecimal("150.00")  # Provider says $150
    )

    # Create a trade that gives us a different cost basis
    create_trade(@aapl, account: @account, qty: 10, price: 180, date: Date.current)

    # Use :reverse strategy - with trades, it should compute cost_basis from them
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding = @account.holdings.find_by(security: @aapl, date: Date.current)
    assert_equal BigDecimal("180.00"), holding.cost_basis,
      "Trade-derived cost_basis should override provider cost_basis when available"
  end

  # --- Transfers and the stored cost basis (w2-transfers wac-cost-basis) ---

  # Materialized first and relabelled after: the case that matters is a position already
  # carrying a figure worked out before anyone knew the movement was a transfer
  test "a transfer clears a cost basis this app had worked out" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    assert_equal 200, latest_holding.cost_basis.to_d

    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis
    assert_nil latest_holding.cost_basis_source
    assert_nil latest_holding.avg_cost
  end

  test "a transfer clears a stored basis that recorded no source" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 200, cost_basis_source: nil)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis
  end

  test "a transfer leaves a provider cost basis alone" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 150, cost_basis_source: "provider")
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 150, latest_holding.cost_basis.to_d
  end

  test "a manual cost basis survives a transfer" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 1.day.ago.to_date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date).set_manual_cost_basis!(BigDecimal("120"))

    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    today = latest_holding
    assert_equal BigDecimal("120"), today.cost_basis
    assert_equal "manual", today.cost_basis_source
    assert today.cost_basis_locked?
  end

  test "an ordinary purchase still gets its calculated basis" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 200, latest_holding.cost_basis.to_d
    assert_equal "calculated", latest_holding.cost_basis_source
  end

  private
    def latest_holding
      @account.holdings.where(security: @aapl).order(:date).last
    end
end
