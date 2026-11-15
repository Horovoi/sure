require "test_helper"

class CryptosControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:crypto)
  end

  test "create keeps the subtype from the accountable fields" do
    post cryptos_path, params: {
      account: {
        name: "New Crypto", balance: 1000, currency: "USD", accountable_type: "Crypto",
        accountable_attributes: { subtype: "exchange" }
      }
    }

    assert_equal "exchange", Account.order(:created_at).last.subtype
  end

  test "update changes the subtype" do
    patch crypto_path(@account), params: {
      account: { name: @account.name, accountable_attributes: { id: @account.accountable_id, subtype: "exchange" } }
    }

    assert_equal "exchange", @account.reload.subtype
  end
end
