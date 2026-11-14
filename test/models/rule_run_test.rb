require "test_helper"

class RuleRunTest < ActiveSupport::TestCase
  setup do
    @rule = rules(:one)
    @run = RuleRun.create!(
      rule: @rule, rule_name: "Test", execution_type: "manual",
      pending_jobs_count: 2, executed_at: Time.current
    )
  end

  test "starts pending" do
    assert @run.pending?
  end

  test "succeeds when the last job slot is released" do
    RuleRun.find(@run.id).complete_job!(modified_count: 3)
    assert @run.reload.pending?
    assert_equal 1, @run.pending_jobs_count

    RuleRun.find(@run.id).complete_job!(modified_count: 2)
    @run.reload
    assert @run.success?
    assert_equal 0, @run.pending_jobs_count
    assert_equal 5, @run.transactions_modified
  end

  test "register_job! reserves a slot atomically" do
    @run.register_job!
    assert_equal 3, @run.reload.pending_jobs_count
  end

  test "completing a job on a failed run updates counts without changing state" do
    @run.fail!("boom")
    RuleRun.find(@run.id).complete_job!(modified_count: 1)
    RuleRun.find(@run.id).complete_job!(modified_count: 1)

    @run.reload
    assert @run.failed?
    assert_equal 0, @run.pending_jobs_count
    assert_equal 2, @run.transactions_modified
  end

  test "an extra completion never takes the count below zero" do
    3.times { RuleRun.find(@run.id).complete_job! }
    assert_equal 0, @run.reload.pending_jobs_count
    assert @run.success?
  end

  test "fail_job! fails the run and keeps the error" do
    RuleRun.find(@run.id).fail_job!(StandardError.new("LLM down"))
    @run.reload
    assert @run.failed?
    assert_equal 1, @run.pending_jobs_count
    assert_equal "StandardError: LLM down", @run.error_message
  end

  test "cannot succeed while jobs are outstanding" do
    assert_raises(AASM::InvalidTransition) { @run.succeed! }
  end

  test "stale scope finds old pending runs only" do
    old = RuleRun.create!(rule: @rule, execution_type: "manual", executed_at: 3.hours.ago, created_at: 3.hours.ago)
    RuleRun.create!(rule: @rule, execution_type: "manual", executed_at: 3.hours.ago, created_at: 3.hours.ago, status: "success")

    assert_equal [ old ], RuleRun.stale.to_a
  end
end
