require "test_helper"

class AutoEnrichmentJobsTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @run = RuleRun.create!(rule: rules(:one), execution_type: "manual", executed_at: Time.current, pending_jobs_count: 1)
  end

  test "AutoCategorizeJob reports its modified count to the run" do
    Family.any_instance.stubs(:auto_categorize_transactions).returns(4)

    AutoCategorizeJob.perform_now(@family, transaction_ids: [], rule_run_id: @run.id)

    @run.reload
    assert @run.success?
    assert_equal 4, @run.transactions_modified
  end

  test "AutoCategorizeJob failure fails the run instead of leaving it pending" do
    Family.any_instance.stubs(:auto_categorize_transactions).raises(Family::AutoCategorizer::Error, "No LLM provider")

    assert_nothing_raised do
      AutoCategorizeJob.perform_now(@family, transaction_ids: [], rule_run_id: @run.id)
    end

    @run.reload
    assert @run.failed?
    assert_equal 0, @run.pending_jobs_count
    assert_match "No LLM provider", @run.error_message
  end

  test "AutoDetectMerchantsJob failure fails the run" do
    Family.any_instance.stubs(:auto_detect_transaction_merchants).raises(Family::AutoMerchantDetector::Error, "LLM down")

    AutoDetectMerchantsJob.perform_now(@family, transaction_ids: [], rule_run_id: @run.id)

    assert @run.reload.failed?
  end

  test "failure outside a rule run re-raises for Sidekiq" do
    Family.any_instance.stubs(:auto_detect_transaction_merchants).raises(Family::AutoMerchantDetector::Error, "LLM down")

    assert_raises(Family::AutoMerchantDetector::Error) do
      AutoDetectMerchantsJob.perform_now(@family, transaction_ids: [])
    end
  end

  test "auto-categorize and merchant detection run in the AI lane's low-priority queue" do
    assert_equal "ai_low_priority", AutoCategorizeJob.queue_name
    assert_equal "ai_low_priority", AutoDetectMerchantsJob.queue_name
  end
end
