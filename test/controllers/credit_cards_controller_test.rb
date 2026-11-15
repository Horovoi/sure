require "test_helper"

class CreditCardsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest
  include BalanceTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:credit_card)
  end

  test "creates with credit card details" do
    assert_difference -> { Account.count } => 1,
      -> { CreditCard.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post credit_cards_path, params: {
        account: {
          name: "New Credit Card",
          balance: 1000,
          currency: "USD",
          institution_name: "Amex",
          institution_domain: "americanexpress.com",
          notes: "Primary card",
          accountable_type: "CreditCard",
          accountable_attributes: {
            available_credit: 5000,
            minimum_payment: 25.51,
            apr: 15.99,
            expiration_date: 2.years.from_now.to_date,
            annual_fee: 99
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Credit Card", created_account.name
    assert_equal 1000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Amex", created_account[:institution_name]
    assert_equal "americanexpress.com", created_account[:institution_domain]
    assert_equal "Primary card", created_account[:notes]
    assert_equal 5000, created_account.accountable.available_credit
    assert_equal 25.51, created_account.accountable.minimum_payment
    assert_equal 15.99, created_account.accountable.apr
    assert_equal 2.years.from_now.to_date, created_account.accountable.expiration_date
    assert_equal 99, created_account.accountable.annual_fee

    assert_redirected_to created_account
    assert_equal "Credit card account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with credit card details" do
    assert_no_difference [ "Account.count", "CreditCard.count" ] do
      patch credit_card_path(@account), params: {
        account: {
          name: "Updated Credit Card",
          balance: 2000,
          currency: "USD",
          institution_name: "Chase",
          institution_domain: "chase.com",
          notes: "Updated notes",
          accountable_type: "CreditCard",
          accountable_attributes: {
            id: @account.accountable_id,
            available_credit: 6000,
            minimum_payment: 50,
            apr: 14.99,
            expiration_date: 3.years.from_now.to_date,
            annual_fee: 0
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Credit Card", @account.name
    assert_equal 2000, @account.balance
    assert_equal "Chase", @account[:institution_name]
    assert_equal "chase.com", @account[:institution_domain]
    assert_equal "Updated notes", @account[:notes]
    assert_equal 6000, @account.accountable.available_credit
    assert_equal 50, @account.accountable.minimum_payment
    assert_equal 14.99, @account.accountable.apr
    assert_equal 3.years.from_now.to_date, @account.accountable.expiration_date
    assert_equal 0, @account.accountable.annual_fee

    assert_redirected_to @account
    assert_equal "Credit card account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end
  test "creates with the statement cycle days" do
    post credit_cards_path, params: {
      account: {
        name: "Cycle Card",
        balance: 500,
        currency: "USD",
        accountable_type: "CreditCard",
        accountable_attributes: { statement_close_day: 31, due_day: 20 }
      }
    }

    card = Account.order(:created_at).last.accountable
    assert_equal 31, card.statement_close_day
    assert_equal 20, card.due_day
  end

  test "updates and clears the statement cycle days" do
    patch credit_card_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, statement_close_day: 25, due_day: 5 } }
    }

    assert_redirected_to @account
    assert_equal [ 25, 5 ], [ @account.accountable.reload.statement_close_day, @account.accountable.due_day ]

    patch credit_card_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, statement_close_day: "", due_day: "" } }
    }

    assert_equal [ nil, nil ], [ @account.accountable.reload.statement_close_day, @account.accountable.due_day ]
  end

  test "the edit form has the statement cycle days" do
    get edit_credit_card_path(@account)

    assert_response :ok
    assert_select "select[name='account[accountable_attributes][statement_close_day]'] option[value='31']", text: "31st"
    assert_select "select[name='account[accountable_attributes][due_day]'] option[value='1']", text: "1st"
  end

  test "the overview tab shows the statement figures" do
    travel_to Time.utc(2026, 10, 16, 12) do
      @account.accountable.update!(statement_close_day: 25, due_day: 5, apr: 18, minimum_payment: 100)
      create_balance(account: @account, date: Date.new(2026, 9, 1), balance: 1_000)
      create_balance(account: @account, date: Date.new(2026, 10, 1), balance: 1_200)
      @account.entries.create!(name: "Groceries", date: Date.new(2026, 10, 1), amount: 200, currency: "USD", entryable: Transaction.new)

      get account_path(@account)

      assert_response :ok
      assert_select "[role='tab'], button, a", text: I18n.t("UI.account_page.tabs.overview")
      assert_select "[data-testid='credit-card-statement-balance']" do
        assert_select "h4", text: I18n.t("credit_cards.tabs.overview.statement_balance")
        assert_select "p", text: /\$1,000\.00/
        assert_select "span", text: I18n.t("credit_cards.tabs.overview.due_on", date: I18n.l(Date.new(2026, 10, 5), format: :long))
        assert_select "span", text: I18n.t("credit_cards.due.overdue", count: 11)
      end
      assert_select "[data-testid='credit-card-since-last-statement'] p", text: /\$200\.00/
      assert_select "[data-testid='credit-card-apr'] span", text: I18n.t("credit_cards.tabs.overview.per_month", amount: "$15.00")
    end
  end

  test "the overview tab asks for the cycle when none is set" do
    @account.accountable.update!(statement_close_day: nil, due_day: nil)

    get account_path(@account)

    assert_response :ok
    assert_match I18n.t("credit_cards.tabs.overview.no_cycle_title"), response.body
  end
end
