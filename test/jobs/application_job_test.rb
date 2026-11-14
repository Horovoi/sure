require "test_helper"

class ApplicationJobTest < ActiveJob::TestCase
  class CanaryJob < ApplicationJob
    def perform; end
  end

  test "a job enqueued inside a transaction waits for the commit" do
    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      CanaryJob.perform_later
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == CanaryJob }
    end

    assert_not enqueued_mid_transaction, "the job was enqueued before the transaction committed"
    assert_enqueued_with job: CanaryJob
  end

  test "a job enqueued inside a transaction that rolls back is dropped" do
    assert_no_enqueued_jobs do
      ActiveRecord::Base.transaction do
        CanaryJob.perform_later
        raise ActiveRecord::Rollback
      end
    end
  end

  test "a job enqueued outside a transaction is enqueued at once" do
    assert_enqueued_with job: CanaryJob do
      CanaryJob.perform_later
    end
  end

  test "framework jobs wait for the commit too" do
    assert ActionMailer::MailDeliveryJob.enqueue_after_transaction_commit
  end

  test "a sync job is not enqueued while the transaction that creates the sync is open" do
    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      accounts(:depository).sync_later
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == SyncJob }
    end

    assert_not enqueued_mid_transaction, "SyncJob was enqueued before its Sync row was committed"
    assert_enqueued_with job: SyncJob
  end
end
