require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create keeps the subtype and the start date" do
    post depositories_path, params: {
      account: {
        name: "Savings", balance: 2500, subtype: "savings", currency: "USD",
        accountable_type: "Depository", opening_balance_date: 3.months.ago.to_date.iso8601
      }
    }

    created = Account.order(:created_at).last
    assert_equal "savings", created.subtype
    assert_equal 3.months.ago.to_date, created.valuations.opening_anchor.first.entry.date
    assert_equal 2500, created.valuations.opening_anchor.first.entry.amount
  end

  test "create without a start date opens two years back" do
    post depositories_path, params: {
      account: { name: "Checking", balance: 100, currency: "USD", accountable_type: "Depository" }
    }

    created = Account.order(:created_at).last
    assert_equal 2.years.ago.to_date, created.valuations.opening_anchor.first.entry.date
  end

  test "create rejects a malformed or future start date" do
    [ "not-a-date", 1.day.from_now.to_date.iso8601 ].each do |value|
      assert_no_difference "Account.count" do
        post depositories_path, params: {
          account: { name: "Bad Date", balance: 100, currency: "USD", accountable_type: "Depository", opening_balance_date: value }
        }
      end

      assert_response :unprocessable_entity
      assert_select "input[name='account[name]'][value='Bad Date']", count: 1
    end
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation keeps it in the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path)

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created)
  end

  test "update with an unchanged balance does not sync" do
    assert_no_enqueued_jobs only: SyncJob do
      patch depository_path(@account), params: {
        account: { name: "Renamed", balance: @account.balance, currency: @account.currency }
      }
    end

    assert_equal "Renamed", @account.reload.name
  end

  test "update cannot change the account type" do
    patch depository_path(@account), params: {
      account: { name: @account.name, accountable_type: "Loan" }
    }

    assert_equal "Depository", @account.reload.accountable_type
  end
end
