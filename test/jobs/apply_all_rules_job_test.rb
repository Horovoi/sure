require "test_helper"

class ApplyAllRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "applies all active rules for a family" do
    rule = create_rule(name: "Whole Foods")

    # Mock RuleJob to verify it gets called for each rule
    RuleJob.expects(:perform_now).with(rule, ignore_attribute_locks: true, execution_type: "manual").once

    ApplyAllRulesJob.perform_now(@family)
  end

  test "applies all rules with custom execution type" do
    rule = create_rule(name: "Test")

    RuleJob.expects(:perform_now).with(rule, ignore_attribute_locks: true, execution_type: "scheduled").once

    ApplyAllRulesJob.perform_now(@family, execution_type: "scheduled")
  end

  test "skips inactive rules" do
    create_rule(name: "Draft", active: false)

    RuleJob.expects(:perform_now).never

    ApplyAllRulesJob.perform_now(@family)
  end

  test "a failing rule does not stop the others" do
    first = create_rule(name: "First")
    second = create_rule(name: "Second")

    RuleJob.expects(:perform_now).with(first, ignore_attribute_locks: true, execution_type: "manual").raises(StandardError, "boom")
    RuleJob.expects(:perform_now).with(second, ignore_attribute_locks: true, execution_type: "manual").once

    assert_nothing_raised { ApplyAllRulesJob.perform_now(@family) }
  end

  private
    def create_rule(name:, active: true)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: active,
        effective_date: 1.day.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: name) ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
      )
    end
end
