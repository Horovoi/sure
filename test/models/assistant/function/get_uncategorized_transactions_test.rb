require "test_helper"

class Assistant::Function::GetUncategorizedTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @fn = Assistant::Function::GetUncategorizedTransactions.new(@user)
  end

  test "is a read tool" do
    assert_equal :read, @fn.scope_tag
    assert @fn.class.read_only?
  end

  test "groups uncategorized spending by payee, largest first, never netting income" do
    2.times { |i| create_transaction(name: "  silpo  ", amount: 100 + i, date: (i + 1).days.ago.to_date) }
    create_transaction(name: "Salary", amount: -5000)
    create_transaction(name: "Categorized", amount: 999, category: categories(:food_and_drink))

    result = @fn.call

    silpo = result[:payees].find { |payee| payee[:payee] == "SILPO" }
    assert_equal 2, silpo[:transaction_count]
    assert_equal "expense", silpo[:classification]
    assert_equal "201.0", silpo[:total_amount]
    assert_equal 2, silpo[:transaction_ids].size

    salary = result[:payees].find { |payee| payee[:payee] == "SALARY" }
    assert_equal "income", salary[:classification]
    assert_equal "5000.0", salary[:total_amount]
    assert_equal result[:payees].first, salary

    usd = result[:totals_by_currency]["USD"]
    assert_equal "201.0", usd[:expense][:amount]
    assert_equal "5000.0", usd[:income][:amount]
    assert_nil result[:payees].find { |payee| payee[:payee] == "CATEGORIZED" }
  end

  test "transfers between own accounts are never listed, loan payments are spending" do
    loan_payment = create_transaction(name: "Mortgage payment", amount: -300, kind: "loan_payment")

    result = @fn.call
    names = result[:payees].map { |payee| payee[:payee] }

    assert_not_includes names, "PAYMENT TO CREDIT CARD ACCOUNT"
    assert_not_includes names, "PAYMENT RECEIVED FROM CHECKING ACCOUNT"
    group = result[:payees].find { |payee| payee[:transaction_ids].include?(loan_payment.id) }
    assert_equal "expense", group[:classification]
  end

  test "excluded rows and other accounts are left out" do
    create_transaction(name: "Hidden", amount: 10, excluded: true)
    create_transaction(name: "Card coffee", amount: 4, account: accounts(:credit_card))

    names = @fn.call("account_ids" => [ @account.id ])[:payees].map { |payee| payee[:payee] }

    assert_not_includes names, "HIDDEN"
    assert_not_includes names, "CARD COFFEE"
    assert_empty @fn.call("account_ids" => [ "not-a-uuid" ])[:payees]
  end

  test "the window is bounded and the limit is clamped" do
    result = @fn.call("start_date" => "2000-01-01", "end_date" => Date.current.iso8601, "limit" => 500)

    assert_equal Date.current - Assistant::Function::GetUncategorizedTransactions::MAX_LOOKBACK_DAYS, result[:period][:start_date]
    assert result[:payees].size <= Assistant::Function::GetUncategorizedTransactions::MAX_PAYEES
  end

  test "reports whether an active rule sets categories" do
    assert_equal 0, @fn.call[:rules][:active_categorizing_rules]
    assert @fn.call[:rules][:note].present?
  end

  private
    def create_transaction(name:, amount:, date: 1.day.ago.to_date, category: nil, kind: "standard", excluded: false, account: @account)
      account.entries.create!(
        name: name, date: date, amount: amount, currency: "USD", excluded: excluded,
        entryable: Transaction.new(category: category, kind: kind)
      ).transaction
    end
end
