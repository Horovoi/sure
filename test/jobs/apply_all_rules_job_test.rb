require "test_helper"

class ApplyAllRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "runs every active rule in one ordered pass with locks ignored" do
    ApplyRulesJob.expects(:perform_now).with(@family, execution_type: "manual", ignore_attribute_locks: true).once

    ApplyAllRulesJob.perform_now(@family)
  end

  test "passes a custom execution type through" do
    ApplyRulesJob.expects(:perform_now).with(@family, execution_type: "scheduled", ignore_attribute_locks: true).once

    ApplyAllRulesJob.perform_now(@family, execution_type: "scheduled")
  end

  test "skips inactive rules" do
    draft = create_rule(name: "Draft", active: false)

    ApplyAllRulesJob.perform_now(@family)

    assert_empty draft.rule_runs
  end

  test "a failing rule does not stop the others" do
    create_transaction(account: @account, name: "First and Second")
    first = create_rule(name: "First")
    second = create_rule(name: "Second", action: Rule::Action.new(action_type: "set_transaction_name", value: "Renamed"))
    Rule::ActionExecutor::SetTransactionCategory.any_instance.stubs(:execute).raises(StandardError, "boom")

    assert_nothing_raised { ApplyAllRulesJob.perform_now(@family) }

    assert first.rule_runs.sole.failed?
    assert second.rule_runs.sole.success?
  end

  private
    def create_rule(name:, active: true, action: nil)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: active,
        effective_date: 1.day.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: name) ],
        actions: [ action || Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
      )
    end
end
