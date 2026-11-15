require "test_helper"

class RuleJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule job", balance: 1000, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Groceries")
    @entry = create_transaction(date: Date.current, account: @account, name: "Whole Foods")
  end

  test "runs the rule through the ordered runner" do
    rule = build_rule

    ApplyRulesJob.expects(:perform_now).with(@family, rule_ids: [ rule.id ], ignore_attribute_locks: true, execution_type: "scheduled")

    RuleJob.perform_now(rule, ignore_attribute_locks: true, execution_type: "scheduled")
  end

  test "a job queued before the ordered runner still applies its rule" do
    rule = build_rule

    RuleJob.perform_now(rule)

    run = rule.rule_runs.sole
    assert run.success?
    assert_equal "manual", run.execution_type
    assert_equal @category, @entry.transaction.reload.category
  end

  test "apply_later queues one ordered run for the rule" do
    rule = build_rule

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family, { rule_ids: [ rule.id ], ignore_attribute_locks: false, execution_type: "scheduled" } ]) do
      rule.apply_later(execution_type: "scheduled")
    end
  end

  test "failure marks the run failed and does not raise, so a retry cannot create a second run" do
    rule = build_rule
    Rule.any_instance.stubs(:apply).raises(StandardError, "boom")

    assert_nothing_raised { RuleJob.perform_now(rule) }

    run = rule.rule_runs.sole
    assert run.failed?
    assert_equal "StandardError: boom", run.error_message
  end

  private
    def build_rule
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
      )
    end
end
