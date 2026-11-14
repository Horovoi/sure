require "test_helper"

class OtherAssetsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:other_asset)
  end

  test "create ignores an external return_to and redirects to the new account" do
    post other_assets_path, params: {
      account: {
        name: "Art",
        balance: 1000,
        currency: "USD",
        accountable_type: "OtherAsset",
        return_to: "https://evil.example/phish"
      }
    }

    assert_redirected_to account_path(Account.order(:created_at).last)
  end

  test "create follows a relative return_to" do
    post other_assets_path, params: {
      account: { name: "Art", balance: 1000, currency: "USD", accountable_type: "OtherAsset", return_to: "/accounts" }
    }

    assert_redirected_to "/accounts"
  end
end
