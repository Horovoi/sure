require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal "mortgage", created_account.accountable.subtype
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "auto",
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "create keeps the current balance when the original balance differs" do
    post loans_path, params: {
      account: {
        name: "Car Loan", balance: 8000, currency: "USD", accountable_type: "Loan",
        opening_balance_date: 1.year.ago.to_date.iso8601,
        accountable_attributes: { initial_balance: 12000, rate_type: "fixed", interest_rate: 5, term_months: 48 }
      }
    }

    created_account = Account.order(:created_at).last
    assert_equal 1.year.ago.to_date, created_account.valuations.opening_anchor.first.entry.date
    assert_equal 12000, created_account.valuations.opening_anchor.first.entry.amount
    assert_equal 8000, created_account.entries.valuations.find_by(date: Date.current).amount
  end

  test "a late create failure renders the form with what was typed" do
    invalid_entry = Entry.new.tap(&:validate)
    Account::OpeningBalanceManager.any_instance.stubs(:set_opening_balance)
      .raises(ActiveRecord::RecordInvalid.new(invalid_entry))

    assert_no_difference "Account.count" do
      post loans_path, params: { account: {
        name: "Loan With Bad Anchor", balance: 50_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { interest_rate: 6, rate_type: "fixed", term_months: 60 }
      } }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{loans_path}']", count: 1
    assert_select "input[name='account[name]'][value='Loan With Bad Anchor']", count: 1
    assert_select "input[name='account[accountable_attributes][interest_rate]'][value='6']", count: 1
  end

  test "a late create failure renders the loan's fields even when the form sent none" do
    invalid_entry = Entry.new.tap(&:validate)
    Account::OpeningBalanceManager.any_instance.stubs(:set_opening_balance)
      .raises(ActiveRecord::RecordInvalid.new(invalid_entry))

    assert_no_difference "Account.count" do
      post loans_path, params: { account: {
        name: "Loan Without Nested Attributes", balance: 50_000, currency: "USD", accountable_type: "Loan"
      } }
    end

    assert_response :unprocessable_entity
    assert_select "input[name='account[name]'][value='Loan Without Nested Attributes']", count: 1
    assert_select "input[name='account[accountable_attributes][interest_rate]']", minimum: 1
  end

  test "an unknown loan subtype comes back as the form with an error" do
    assert_no_difference "Account.count" do
      post loans_path, params: { account: {
        name: "Odd Loan", balance: 1000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { subtype: "payday" }
      } }
    end

    assert_response :unprocessable_entity
  end
end
