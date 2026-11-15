require "test_helper"

class Account::OutsideEnabledProvidersTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    item = @family.lunchflow_items.create!(name: "Bank", api_key: "key")
    @lunchflow_linked = @family.accounts.create!(name: "LF", balance: 0, currency: "USD", accountable: Depository.new)
    Account::ProviderLink.link!(account: @lunchflow_linked, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"))
    @plaid_linked = accounts(:connected)
  end

  test "every account while no provider is on" do
    assert_equal @family.accounts.count, @family.accounts.outside_enabled_providers.count
  end

  test "leaves out the accounts of the enabled providers only" do
    enable_bank_connections(:lunchflow)
    ids = @family.accounts.outside_enabled_providers.pluck(:id)
    assert_not_includes ids, @lunchflow_linked.id
    assert_includes ids, @plaid_linked.id

    enable_bank_connections(:plaid)
    ids = @family.accounts.outside_enabled_providers.pluck(:id)
    assert_includes ids, @lunchflow_linked.id
    assert_not_includes ids, @plaid_linked.id
  end

  test "with every provider on it is the manual accounts" do
    enable_bank_connections

    assert_equal @family.accounts.manual.pluck(:id).sort, @family.accounts.outside_enabled_providers.pluck(:id).sort
  end
end
