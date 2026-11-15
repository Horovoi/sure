require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "syncs only visible manual accounts while bank connections are off" do
    family_sync = syncs(:family)
    @family.accounts.manual.first.update_columns(status: "pending_deletion")

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(@family.accounts.visible.manual.count)
    PlaidItem.any_instance.expects(:sync_later).never

    Family::Syncer.new(@family).perform_sync(family_sync)
  end

  test "syncs plaid items and manual accounts" do
    BankConnections.stubs(:enabled?).returns(true)
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
end
