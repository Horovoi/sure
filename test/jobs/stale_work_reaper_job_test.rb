require "test_helper"

class StaleWorkReaperJobTest < ActiveJob::TestCase
  test "fails exports stuck in processing and leaves recent ones alone" do
    family = families(:dylan_family)
    stuck = family.family_exports.create!(status: "processing")
    stuck.update_columns(updated_at: 2.hours.ago)
    fresh = family.family_exports.create!(status: "processing")

    result = StaleWorkReaperJob.perform_now

    assert_equal "failed", stuck.reload.status
    assert_equal "processing", fresh.reload.status
    assert_equal 1, result["FamilyExport"]
  end

  test "fails imports stuck importing" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 1.hour.ago)

    StaleWorkReaperJob.perform_now

    assert_equal "failed", import.reload.status
    assert import.error.present?
  end

  test "fails assistant turns that never finished" do
    turn = AssistantMessage.create!(chat: chats(:one), ai_model: "gpt-4.1", status: "streaming", content: "Partial")
    turn.update_columns(updated_at: 1.hour.ago)

    result = StaleWorkReaperJob.perform_now

    assert_equal "failed", turn.reload.status
    assert_equal 1, result["AssistantMessage"]
  end

  test "fails rule runs whose jobs never reported back" do
    rule = families(:dylan_family).rules.create!(resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    run = RuleRun.create!(rule: rule, rule_name: "r", execution_type: "manual", status: "pending", pending_jobs_count: 1, executed_at: 3.hours.ago)
    run.update_columns(created_at: 3.hours.ago, updated_at: 3.hours.ago)

    StaleWorkReaperJob.perform_now

    assert_equal "failed", run.reload.status
  end

  test "completes impersonation sessions past their TTL and detaches browser sessions" do
    expired = impersonation_sessions(:in_progress)
    expired.update_columns(updated_at: 3.hours.ago)
    session = expired.impersonator.sessions.create!(active_impersonator_session_id: expired.id)

    result = StaleWorkReaperJob.perform_now

    assert_equal "complete", expired.reload.status
    assert_nil session.reload.active_impersonator_session_id
    assert_equal 1, result["ImpersonationSession"]
  end

  test "is scheduled every 15 minutes" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    assert_equal "StaleWorkReaperJob", schedule.dig("reap_stale_work", "class")
  end
end
