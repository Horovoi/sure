require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "syncs every visible account while bank connections are off, linked ones included" do
    family_sync = syncs(:family)
    @family.accounts.manual.first.update_columns(status: "pending_deletion")
    assert @family.accounts.visible.where.not(plaid_account_id: nil).exists?, "fixtures should have a plaid-linked account"

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(@family.accounts.visible.count)
    PlaidItem.any_instance.expects(:sync_later).never

    Family::Syncer.new(@family).perform_sync(family_sync)
  end

  test "syncs plaid items and manual accounts" do
    enable_bank_connections
    family_sync = syncs(:family)

    manual_accounts_count = @family.accounts.visible.manual.count
    items_count = @family.plaid_items.active.count

    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(manual_accounts_count)

    PlaidItem.any_instance
             .expects(:sync_later)
             .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
             .times(items_count)

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "an account linked to a provider that is off syncs on its own, the enabled provider's items sync" do
    enable_bank_connections(:lunchflow)
    plaid_linked = @family.accounts.visible.where.not(plaid_account_id: nil).to_a
    assert plaid_linked.any?, "fixtures should have a plaid-linked account"
    item = @family.lunchflow_items.create!(name: "Bank", api_key: "key")
    lunchflow_linked = @family.accounts.create!(name: "LF", balance: 0, currency: "USD", accountable: Depository.new)
    Account::ProviderLink.link!(account: lunchflow_linked, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"))

    syncables = Family::Syncer.new(@family).send(:child_syncables)

    assert_includes syncables, item
    plaid_linked.each { |account| assert_includes syncables, account }
    assert_not_includes syncables, lunchflow_linked
    assert_empty syncables.grep(PlaidItem)
    assert_equal @family.accounts.visible.count - 1, syncables.grep(Account).size
  end

  test "post-sync enqueues one ordered rule run for the family" do
    @family.rules.destroy_all
    2.times do
      @family.rules.create!(resource_type: "transaction", active: true, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    @family.rules.create!(resource_type: "transaction", active: false, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    Family.any_instance.stubs(:auto_match_transfers!)

    assert_enqueued_jobs 1, only: ApplyRulesJob do
      assert_no_enqueued_jobs only: RuleJob do
        Family::Syncer.new(@family).perform_post_sync
      end
    end

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family, { execution_type: "scheduled" } ])
  end

  test "post-sync enqueues no rule run when the family has no active rules" do
    @family.rules.update_all(active: false)
    Family.any_instance.stubs(:auto_match_transfers!)

    assert_no_enqueued_jobs only: ApplyRulesJob do
      Family::Syncer.new(@family).perform_post_sync
    end
  end

  test "syncs every active provider item type while bank connections are on" do
    enable_bank_connections
    family_sync = syncs(:family)
    @family.enable_banking_items.create!(name: "Test Enable Banking", country_code: "FI", application_id: "app-id", client_certificate: "cert")
    @family.coinstats_items.create!(name: "Test CoinStats", api_key: "coinstats-key")
    @family.coinbase_items.create!(name: "Test Coinbase", api_key: "coinbase-key", api_secret: "coinbase-secret")
    @family.coinbase_items.create!(name: "Deleted Coinbase", api_key: "old-key", api_secret: "old-secret", scheduled_for_deletion: true)

    Account.any_instance.stubs(:sync_later)
    [ PlaidItem, LunchflowItem, EnableBankingItem, CoinstatsItem ].each do |item_class|
      item_class.any_instance.expects(:sync_later).times(item_class.where(family: @family).active.count)
    end
    CoinbaseItem.any_instance.expects(:sync_later).once

    Family::Syncer.new(@family).perform_sync(family_sync)
  end

  test "syncs no provider item type while bank connections are off" do
    family_sync = syncs(:family)
    @family.coinstats_items.create!(name: "Test CoinStats", api_key: "coinstats-key")

    Account.any_instance.stubs(:sync_later)
    [ PlaidItem, LunchflowItem, EnableBankingItem, CoinstatsItem, CoinbaseItem ].each do |item_class|
      item_class.any_instance.expects(:sync_later).never
    end

    Family::Syncer.new(@family).perform_sync(family_sync)
  end
end
