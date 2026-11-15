require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
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

  private
    def create_provider_items
      @family.enable_banking_items.create!(name: "Test Enable Banking", country_code: "FI", application_id: "app-id", client_certificate: "cert")
      @family.coinstats_items.create!(name: "Test CoinStats", api_key: "coinstats-key")
      @family.coinbase_items.create!(name: "Test Coinbase", api_key: "coinbase-key", api_secret: "coinbase-secret")
    end
end
