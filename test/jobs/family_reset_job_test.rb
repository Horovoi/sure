require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
    # The pre-reset bundle (pg_dump and tar) is covered by Backup::BundleTest
    Backup::Bundle.stubs(:create!).returns(Pathname("/backups/bundles/pre-reset/20261115T040000Z_test"))
  end

  test "resets family data successfully" do
    initial_account_count = @family.accounts.count
    initial_category_count = @family.categories.count

    # Family should have existing data
    assert initial_account_count > 0
    assert initial_category_count > 0

    # Don't expect Plaid removal calls since we're using fixtures without setup
    @plaid_provider.stubs(:remove_item)

    FamilyResetJob.perform_now(@family)

    # All data should be removed
    assert_equal 0, @family.accounts.reload.count
    assert_equal 0, @family.categories.reload.count
  end

  test "creates pre-reset export before destroying data" do
    @plaid_provider.stubs(:remove_item)

    initial_account_count = @family.accounts.count
    assert initial_account_count > 0

    assert_difference -> { @family.family_exports.count }, 1 do
      FamilyResetJob.perform_now(@family)
    end

    export = @family.family_exports.last
    assert_equal "completed", export.status
    assert export.export_file.attached?
    assert export.export_file.filename.to_s.start_with?("pre_reset_")

    # Data should still be destroyed
    assert_equal 0, @family.accounts.reload.count
  end

  test "proceeds with reset even if pre-reset export fails" do
    @plaid_provider.stubs(:remove_item)

    Family::DataExporter.any_instance.stubs(:generate_export).raises(StandardError, "Storage error")

    initial_account_count = @family.accounts.count
    assert initial_account_count > 0

    assert_nothing_raised do
      FamilyResetJob.perform_now(@family)
    end

    assert_equal 0, @family.accounts.reload.count
  end

  test "skips export when family has no accounts" do
    @plaid_provider.stubs(:remove_item)
    @family.accounts.destroy_all

    assert_no_difference -> { @family.family_exports.count } do
      FamilyResetJob.perform_now(@family)
    end
  end

  test "resets family data even when Plaid credentials are invalid" do
    # Use existing plaid item from fixtures
    plaid_item = plaid_items(:one)
    assert_equal @family, plaid_item.family

    initial_plaid_count = @family.plaid_items.count
    assert initial_plaid_count > 0

    # Simulate invalid Plaid credentials error
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    # Job should complete successfully despite the Plaid error
    assert_nothing_raised do
      FamilyResetJob.perform_now(@family)
    end

    # PlaidItem should be deleted
    assert_equal 0, @family.plaid_items.reload.count
  end

  test "reset also removes rules and recurring transactions" do
    @plaid_provider.stubs(:remove_item)
    assert @family.rules.exists? || @family.recurring_transactions.exists?, "fixtures should have rules or recurring transactions"

    FamilyResetJob.perform_now(@family)

    assert_equal 0, @family.rules.reload.count
    assert_equal 0, @family.recurring_transactions.reload.count
  end

  test "reset removes every provider item type and keeps the pre-reset export" do
    @plaid_provider.stubs(:remove_item)
    create_provider_items

    BankConnections::ITEM_ASSOCIATIONS.each do |association|
      assert @family.public_send(association).exists?, "#{association} should exist before the reset"
    end

    FamilyResetJob.perform_now(@family)

    BankConnections::ITEM_ASSOCIATIONS.each do |association|
      assert_equal 0, @family.public_send(association).reload.count, "#{association} should be gone after the reset"
    end
    assert @family.family_exports.reload.where(status: "completed").exists?, "the pre-reset export should survive the reset"
  end

  test "takes the pre-reset bundle before anything is deleted" do
    @plaid_provider.stubs(:remove_item)
    accounts_before = @family.accounts.count
    assert accounts_before > 0

    reset = sequence("reset")
    # The block matcher also checks that nothing was deleted yet when the bundle runs
    Backup::Bundle.expects(:create!)
                  .with { |*args| args == [ { kind: :pre_reset, parts: %i[db storage] } ] && @family.accounts.count == accounts_before }
                  .in_sequence(reset)
                  .returns(Pathname("/backups/bundles/pre-reset/20261115T040000Z_test"))
    @family.expects(:lock!).in_sequence(reset)

    FamilyResetJob.perform_now(@family)

    assert_equal 0, @family.accounts.reload.count
  end

  test "a failed pre-reset bundle deletes nothing and is not retried" do
    @plaid_provider.stubs(:remove_item)
    Backup::Bundle.stubs(:create!).raises(Backup::Bundle::Error, "disk full")
    counts = -> { [ @family.accounts.count, @family.categories.count, @family.rules.count, @family.tags.count, @family.family_exports.count ] }
    before = counts.call
    assert before.first > 0

    assert_nothing_raised do
      FamilyResetJob.perform_now(@family)
    end

    assert_equal before, counts.call
    assert_no_enqueued_jobs only: FamilyResetJob
  end

  test "takes the pre-reset bundle on the staging copy too" do
    @plaid_provider.stubs(:remove_item)
    Backup::Bundle.expects(:create!).with(kind: :pre_reset, parts: %i[db storage])
                  .returns(Pathname("/backups/bundles/pre-reset/20261115T040000Z_test"))

    with_env_overrides("STAGING_CLONE" => "1") do
      FamilyResetJob.perform_now(@family)
    end

    assert_equal 0, @family.accounts.reload.count
  end


  # Savings goals (w2-goals): goals go with the accounts that fund them
  test "deletes the family's goals and their account links" do
    @plaid_provider.stubs(:remove_item)
    goal_ids = @family.goals.pluck(:id)
    assert_not_empty goal_ids

    FamilyResetJob.perform_now(@family)

    assert_equal 0, @family.goals.reload.count
    assert_empty GoalAccount.where(goal_id: goal_ids)
  end

  private
    def create_provider_items
      @family.enable_banking_items.create!(name: "Test Enable Banking", country_code: "FI", application_id: "app-id", client_certificate: "cert")
      @family.coinstats_items.create!(name: "Test CoinStats", api_key: "coinstats-key")
      @family.coinbase_items.create!(name: "Test Coinbase", api_key: "coinbase-key", api_secret: "coinbase-secret")
    end
end
