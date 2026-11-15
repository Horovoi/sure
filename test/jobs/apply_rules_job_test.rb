require "test_helper"

class ApplyRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Apply rules job", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @entry = create_transaction(date: Date.current, account: @account, name: "Whole Foods")
    # AI executors are only offered when an LLM provider is configured
    Provider::Registry.stubs(:get_provider).with(:openai).returns(stub("llm"))
  end

  test "runs every active rule in order and returns their runs" do
    top = build_rule(name: "Top", actions: [ category_action(@groceries) ])
    bottom = build_rule(name: "Bottom", actions: [ category_action(@dining) ])
    build_rule(name: "Draft", active: false, actions: [ category_action(@dining) ])

    runs = ApplyRulesJob.perform_now(@family)

    assert_equal [ top, bottom ], runs.map(&:rule)
    assert_equal %w[scheduled scheduled], runs.map(&:execution_type)
    assert_equal @groceries, @entry.transaction.reload.category
  end

  test "sync-only rule succeeds with its counts" do
    rule = build_rule(actions: [ category_action(@groceries) ])

    ApplyRulesJob.perform_now(@family)

    run = rule.rule_runs.sole
    assert run.success?
    assert_equal 1, run.transactions_queued
    assert_equal 1, run.transactions_processed
    assert_equal 1, run.transactions_modified
    assert_equal 0, run.transactions_blocked
    assert_equal 0, run.pending_jobs_count
  end

  test "a transaction a user lock kept unchanged counts as blocked" do
    @entry.transaction.update!(category: @dining)
    @entry.transaction.lock_attr!(:category_id)
    rule = build_rule(actions: [ category_action(@groceries) ])

    ApplyRulesJob.perform_now(@family, rule_ids: [ rule.id ], ignore_attribute_locks: true, execution_type: "manual")

    run = rule.rule_runs.sole
    assert_equal 1, run.transactions_processed
    assert_equal 0, run.transactions_modified
    assert_equal 1, run.transactions_blocked
    assert_equal @dining, @entry.transaction.reload.category
  end

  test "rule with async jobs stays pending until every job completes, counting sync modifications" do
    rule = build_rule(actions: [ category_action(@groceries), Rule::Action.new(action_type: "auto_detect_merchants") ])

    assert_enqueued_jobs 1, only: AutoDetectMerchantsJob do
      ApplyRulesJob.perform_now(@family)
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

    # The queued job finishes instantly, while the runner still holds its slot
    Family.any_instance.stubs(:auto_detect_transaction_merchants_later).with do |_txns, opts|
      run = RuleRun.find(opts[:rule_run_id])
      run.complete_job!(modified_count: 0)
      assert run.reload.pending?, "run must stay pending while the runner holds its slot"
      true
    end

    ApplyRulesJob.perform_now(@family)

    run = rule.rule_runs.sole
    assert run.success?
    assert_equal 0, run.pending_jobs_count
  end

  test "a failing rule is recorded, the job does not raise and the rules below still run" do
    failing = build_rule(name: "Failing", actions: [ category_action(@groceries) ])
    below = build_rule(name: "Below", actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "Renamed") ])
    Rule::ActionExecutor::SetTransactionCategory.any_instance.stubs(:execute).raises(StandardError, "boom")

    assert_nothing_raised { ApplyRulesJob.perform_now(@family) }

    run = failing.rule_runs.sole
    assert run.failed?
    assert_equal "StandardError: boom", run.error_message
    assert below.rule_runs.sole.success?
    assert_equal "Renamed", @entry.reload.name
  end

  test "a busy family lock reschedules the job and runs nothing" do
    rule = build_rule(actions: [ category_action(@groceries) ])
    Rule::Runner.any_instance.stubs(:with_family_lock).returns(false)

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family, { rule_ids: [ rule.id ], execution_type: "manual", ignore_attribute_locks: true } ]) do
      assert_nothing_raised do
        ApplyRulesJob.perform_now(@family, rule_ids: [ rule.id ], execution_type: "manual", ignore_attribute_locks: true)
      end
    end

    assert_empty rule.rule_runs
    assert_nil @entry.transaction.reload.category
  end

  test "rule_ids runs only those rules and the active rules above them" do
    top = build_rule(name: "Top", actions: [ category_action(@groceries) ])
    middle = build_rule(name: "Middle", actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "Renamed") ])
    bottom = build_rule(name: "Bottom", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    runs = ApplyRulesJob.perform_now(@family, rule_ids: [ middle.id ], execution_type: "manual")

    assert_equal [ top, middle ], runs.map(&:rule)
    assert_empty bottom.rule_runs
    refute @entry.reload.excluded?
  end

  private
    def category_action(category)
      Rule::Action.new(action_type: "set_transaction_category", value: category.id)
    end

    def build_rule(actions:, name: nil, active: true)
      Rule.create!(
        family: @family,
        name: name,
        resource_type: "transaction",
        active: active,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: actions
      )
    end
end
