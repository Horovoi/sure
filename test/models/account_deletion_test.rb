require "test_helper"

class AccountDeletionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:depository)
  end

  test "destroy_later is idempotent: a second click enqueues nothing" do
    assert_enqueued_jobs 1, only: DestroyJob do
      @account.destroy_later
      @account.destroy_later
    end
    assert @account.reload.pending_deletion?
  end

  test "an account that recurring transactions point at can be deleted" do
    recurring = @account.family.recurring_transactions.create!(
      name: "Gym", amount: 30, currency: "USD", expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: 5.days.from_now.to_date,
      default_account: @account, inferred_account: @account
    )
    @account.destroy_later

    DestroyJob.perform_now(@account)

    refute Account.exists?(@account.id)
    assert_nil recurring.reload.default_account_id
    assert_nil recurring.inferred_account_id
  end

  test "a destroy job that runs after the account was restored does nothing" do
    @account.destroy_later
    @account.restore!

    DestroyJob.perform_now(@account)

    assert Account.exists?(@account.id)
    assert @account.reload.disabled?
  end

  test "a failed destroy restores the account instead of leaving it stuck" do
    @account.destroy_later
    Account.any_instance.stubs(:destroy).raises(ActiveRecord::InvalidForeignKey, "boom")

    DestroyJob.perform_now(@account)

    assert_equal "disabled", @account.reload.status
  end

  test "a destroy halted by a callback is treated as a failure" do
    @account.destroy_later
    Account.any_instance.stubs(:destroy).returns(false)

    DestroyJob.perform_now(@account)

    assert_equal "disabled", @account.reload.status
  end

  test "accounts pending deletion report scheduled_for_deletion? so syncs skip them" do
    @account.destroy_later
    assert @account.scheduled_for_deletion?
  end

  test "a failed balance edit does not overwrite the cached balance" do
    manager = Account::CurrentBalanceManager.new(@account)
    manager.stubs(:set_current_balance_for_manual_account).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "nope")
    )
    before = @account.balance

    result = manager.set_current_balance(before + 1000)

    assert_not result.success?
    assert_equal before, @account.reload.balance
  end
end
