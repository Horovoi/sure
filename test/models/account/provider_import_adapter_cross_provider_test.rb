require "test_helper"

# Ensures a provider cannot "claim" another provider's holdings when external_id lookup misses
# and a (security, date, currency) match exists. The fallback path must be scoped by account_provider_id.
class Account::ProviderImportAdapterCrossProviderTest < ActiveSupport::TestCase
  test "does not claim holdings from a different provider when external_id is present and fallback kicks in" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create two different account providers for the SAME account
    # Provider A (e.g., Plaid)
    ap_a = AccountProvider.create!(
      account: investment_account,
      provider: plaid_accounts(:one)
    )

    # Provider B (e.g., Lunchflow)
    lf_item = LunchflowItem.create!(family: families(:dylan_family), name: "LF Conn", api_key: "lf_test_key")
    lfa_b = LunchflowAccount.create!(
      lunchflow_item: lf_item,
      name: "LF Invest",
      account_id: "lf_inv_cross_provider",
      currency: "USD",
      current_balance: 1000
    )
    ap_b = AccountProvider.create!(
      account: investment_account,
      provider: lfa_b
    )

    # Use a date that will not collide with existing fixture holdings for this account
    holding_date = Date.today - 3.days

    # Existing holding created by Provider A for (security, date, currency)
    existing_a = investment_account.holdings.create!(
      security: security,
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: ap_a.id
    )

    # Now import for Provider B with an external_id that doesn't exist yet.
    # Fallback should NOT "claim" Provider A's row because account_provider_id differs.
    # Attempt import for Provider B with a conflicting composite key.
    # Policy: do NOT create a duplicate row and do NOT claim Provider A's row.
    assert_no_difference "investment_account.holdings.count" do
      @result_b = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-b-1",
        source: "lunchflow",
        account_provider_id: ap_b.id,
        delete_future_holdings: false
      )
    end

    # Provider A's holding remains unclaimed (no external_id added) and still owned by A
    existing_a.reload
    assert_nil existing_a.external_id
    assert_equal ap_a.id, existing_a.account_provider_id

    # Adapter returns the existing A row for transparency
    assert_equal existing_a.id, @result_b.id

    # Idempotency: importing again with the same external_id should not create another row
    assert_no_difference "investment_account.holdings.count" do
      again = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-b-1",
        source: "lunchflow",
        account_provider_id: ap_b.id,
        delete_future_holdings: false
      )
      assert_equal existing_a.id, again.id
      # Ensure external_id was NOT attached to A's row (no cross-provider claim)
      assert_nil existing_a.reload.external_id
    end
  end
end
