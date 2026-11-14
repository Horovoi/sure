require "test_helper"

class Import::AccountMappingTest < ActiveSupport::TestCase
  setup do
    @import = imports(:transaction)
    @account = accounts(:depository)
    @import.rows.create!(account: @account.name, date: "01/01/2024", amount: "10", currency: "USD")
  end

  test "matches an active account by name" do
    assert_equal @account, Import::AccountMapping.mappables_by_key(@import)[@account.name]
  end

  test "never matches a disabled account or one being deleted" do
    %w[disabled pending_deletion].each do |state|
      @account.update_column(:status, state)

      assert_nil Import::AccountMapping.mappables_by_key(@import)[@account.name]
      assert_not_includes @import.mappings.accounts.new(import: @import, key: @account.name).selectable_values.map(&:last), @account.id
    end
  end

  test "creating a new account never reuses an existing one with the same name" do
    @account.update_column(:status, "pending_deletion")
    mapping = @import.mappings.create!(type: "Import::AccountMapping", key: @account.name, create_when_empty: true)

    assert_difference -> { @import.family.accounts.count }, 1 do
      mapping.create_mappable!
    end

    assert_not_equal @account, mapping.reload.mappable
    assert_equal @import, mapping.mappable.import
  end
end
