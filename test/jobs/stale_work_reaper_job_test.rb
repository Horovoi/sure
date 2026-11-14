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

  test "is scheduled every 15 minutes" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    assert_equal "StaleWorkReaperJob", schedule.dig("reap_stale_work", "class")
  end
end
