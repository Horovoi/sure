require "test_helper"

class Family::ProviderPostSyncTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "matches transfers, applies rules, reconciles charges and finds patterns" do
    @family.rules.create!(resource_type: "transaction", active: true, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    Family.any_instance.expects(:auto_match_transfers!).once
    RecurringTransaction.expects(:reconcile_charges_for).with(@family).once
    RecurringTransaction.expects(:identify_patterns_for).with(@family).once

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family, { execution_type: "scheduled" } ]) do
      Family::ProviderPostSync.new(@family).run
    end
  end

  test "no rule run without active rules" do
    @family.rules.update_all(active: false)
    Family.any_instance.stubs(:auto_match_transfers!)
    RecurringTransaction.stubs(:reconcile_charges_for)
    RecurringTransaction.stubs(:identify_patterns_for)

    assert_no_enqueued_jobs only: ApplyRulesJob do
      Family::ProviderPostSync.new(@family).run
    end
  end
  test "rules wait for new entries and run at most once per half hour" do
    rule = @family.rules.create!(resource_type: "transaction", active: true, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    Family.any_instance.stubs(:auto_match_transfers!)
    RecurringTransaction.stubs(:reconcile_charges_for)
    RecurringTransaction.stubs(:identify_patterns_for)

    assert_no_enqueued_jobs(only: ApplyRulesJob) { Family::ProviderPostSync.new(@family).run(new_entries: false) }

    RuleRun.create!(rule: rule, rule_name: "r", execution_type: "scheduled", status: "success", executed_at: 10.minutes.ago)
    assert_no_enqueued_jobs(only: ApplyRulesJob) { Family::ProviderPostSync.new(@family).run(new_entries: true) }

    travel 25.minutes
    assert_enqueued_jobs(1, only: ApplyRulesJob) { Family::ProviderPostSync.new(@family).run(new_entries: true) }
  end
end
