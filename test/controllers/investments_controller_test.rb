require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "create keeps the subtype from the accountable fields" do
    post investments_path, params: {
      account: {
        name: "New Investment", balance: 1000, currency: "USD", accountable_type: "Investment",
        accountable_attributes: { subtype: "brokerage" }
      }
    }

    assert_equal "brokerage", Account.order(:created_at).last.subtype
  end

  test "update changes the subtype" do
    patch investment_path(@account), params: {
      account: { name: @account.name, accountable_attributes: { id: @account.accountable_id, subtype: "brokerage" } }
    }

    assert_equal "brokerage", @account.reload.subtype
  end
end
