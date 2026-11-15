require "test_helper"

module AccountableResourceInterfaceTest
  extend ActiveSupport::Testing::Declarative

  test "shows new form" do
    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    get new_polymorphic_url(@account.accountable)
    assert_response :success
  end

  test "shows edit form" do
    get edit_account_url(@account)
    assert_response :success
  end

  test "update saves a currency change and rebuilds the balances" do
    @account.update!(currency: "USD")

    assert_enqueued_with(job: SyncJob) do
      patch send("#{@account.accountable_type.underscore}_path", @account), params: {
        account: { name: @account.name, currency: "EUR" }
      }
    end

    assert_equal "EUR", @account.reload.currency
  end
end
