require "test_helper"

# The provider link flows take the account type from the request. Anything that is
# not an account type must be refused before it reaches the account model.
class ProviderLinkAccountTypeTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "Lunch Flow link refuses an unknown account type" do
    assert_no_difference [ "Account.count", "LunchflowItem.count" ] do
      post link_accounts_lunchflow_items_path, params: { account_ids: [ "1" ], accountable_type: "Kernel" }
    end

    assert_redirected_to new_account_path
    assert_equal I18n.t("lunchflow_items.link_accounts.invalid_account_type"), flash[:alert]
  end

  test "Enable Banking link refuses an unknown account type" do
    assert_no_difference "Account.count" do
      post link_accounts_enable_banking_items_path, params: { account_uids: [ "1" ], accountable_type: "Kernel" }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("enable_banking_items.link_accounts.invalid_account_type"), flash[:alert]
  end
end
