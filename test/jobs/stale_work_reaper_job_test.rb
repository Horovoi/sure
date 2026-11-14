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

  test "is scheduled every 15 minutes" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    assert_equal "StaleWorkReaperJob", schedule.dig("reap_stale_work", "class")
  end
end
