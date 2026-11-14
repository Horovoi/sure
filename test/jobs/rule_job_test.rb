require "test_helper"

class RuleJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule job", balance: 1000, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Groceries")
    @entry = create_transaction(date: Date.current, account: @account, name: "Whole Foods")
    # AI executors are only registered when an LLM provider is configured
    Provider::Registry.stubs(:get_provider).with(:openai).returns(stub("llm"))
  end

  test "sync-only rule succeeds with its modified count" do
    rule = build_rule(actions: [ category_action ])

    RuleJob.perform_now(rule)

    run = rule.rule_runs.sole
    assert run.success?
    assert_equal 1, run.transactions_queued
    assert_equal 1, run.transactions_modified
    assert_equal 0, run.pending_jobs_count
  end

  test "writes the execution type it was given" do
    rule = build_rule(actions: [ category_action ])

    RuleJob.perform_now(rule, execution_type: "scheduled")

    assert_equal "scheduled", rule.rule_runs.sole.execution_type
  end

  test "apply_later passes the execution type through" do
    rule = build_rule(actions: [ category_action ])

    assert_enqueued_with(job: RuleJob, args: [ rule, { ignore_attribute_locks: false, execution_type: "scheduled" } ]) do
      rule.apply_later(execution_type: "scheduled")
    end
  end

  test "rule with async jobs stays pending until every job completes, counting sync modifications" do
    rule = build_rule(actions: [ category_action, Rule::Action.new(action_type: "auto_detect_merchants") ])

    assert_enqueued_jobs 1, only: AutoDetectMerchantsJob do
      RuleJob.perform_now(rule)
    end

    run = rule.rule_runs.sole
    assert run.pending?
    assert_equal 1, run.pending_jobs_count
    assert_equal 1, run.transactions_modified, "sync modifications are kept for mixed rules"

    run.complete_job!(modified_count: 1)
    run.reload
    assert run.success?
    assert_equal 2, run.transactions_modified
  end

  test "a job that finishes before the apply phase ends cannot complete the run early" do
    rule = build_rule(actions: [ Rule::Action.new(action_type: "auto_detect_merchants") ])

    # Simulate the queued job finishing instantly, while RuleJob still holds its slot.
    Family.any_instance.stubs(:auto_detect_transaction_merchants_later).with do |_txns, opts|
      run = RuleRun.find(opts[:rule_run_id])
      run.complete_job!(modified_count: 0)
      assert run.reload.pending?, "run must stay pending while RuleJob holds its slot"
      true
    end

    RuleJob.perform_now(rule)

    run = rule.rule_runs.sole
    assert run.success?
    assert_equal 0, run.pending_jobs_count
  end

  test "failure marks the run failed and does not raise, so a retry cannot create a second run" do
    rule = build_rule(actions: [ category_action ])
    Rule.any_instance.stubs(:apply).raises(StandardError, "boom")

    assert_nothing_raised { RuleJob.perform_now(rule) }

    run = rule.rule_runs.sole
    assert run.failed?
    assert_equal "StandardError: boom", run.error_message
  end

  test "requeues instead of running when the same rule is already being applied" do
    rule = build_rule(actions: [ category_action ])
    RuleJob.any_instance.stubs(:with_rule_lock).returns(false)

    assert_enqueued_with(job: RuleJob, args: [ rule, { ignore_attribute_locks: false, execution_type: "manual" } ]) do
      RuleJob.perform_now(rule)
    end
    assert_empty rule.rule_runs
  end

  private
    def category_action
      Rule::Action.new(action_type: "set_transaction_category", value: @category.id)
    end

    def build_rule(actions:)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: actions
      )
    end
end
