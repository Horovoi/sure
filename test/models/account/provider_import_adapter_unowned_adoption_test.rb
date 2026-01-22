require "test_helper"

# Ensures an "unowned" composite row (no account_provider_id) is fully adopted on
# first collision: attributes are updated, external_id attached, and
# account_provider_id set to the importing provider.
class Account::ProviderImportAdapterUnownedAdoptionTest < ActiveSupport::TestCase
  test "adopts unowned holding on unique-index collision by updating attrs and provider ownership" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a Lunchflow provider for this account (the importer)
    lf_item = LunchflowItem.create!(family: families(:dylan_family), name: "LF Conn", api_key: "lf_test_key")
    lfa = LunchflowAccount.create!(
      lunchflow_item: lf_item,
      name: "LF Invest",
      account_id: "lf_inv_unowned_claim",
      currency: "USD",
      current_balance: 1000
    )
    ap = AccountProvider.create!(account: investment_account, provider: lfa)

    holding_date = Date.today - 4.days

    # Existing composite row without provider ownership (unowned)
    existing_unowned = investment_account.holdings.create!(
      security: security,
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: nil
    )

    # Import for Lunchflow with an external_id that will collide on composite key
    # Adapter should NOT create a new row, but should update the existing one:
    # - qty/price/amount/cost_basis updated
    # - external_id attached
    # - account_provider_id adopted to ap.id
    assert_no_difference "investment_account.holdings.count" do
      @result = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "lunchflow",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
    end

    existing_unowned.reload

    # Attributes updated
    assert_equal 2, existing_unowned.qty
    assert_equal 110, existing_unowned.price
    assert_equal 220, existing_unowned.amount

    # Ownership and external_id adopted
    assert_equal ap.id, existing_unowned.account_provider_id
    assert_equal "ext-unowned-1", existing_unowned.external_id

    # Adapter returns the same row
    assert_equal existing_unowned.id, @result.id

    # Idempotency: re-import should not create a duplicate and should return the same row
    assert_no_difference "investment_account.holdings.count" do
      again = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "lunchflow",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
      assert_equal existing_unowned.id, again.id
    end
  end
end
