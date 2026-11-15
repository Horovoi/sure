require "test_helper"

class Transaction::Grouper::ByMerchantOrNameTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # Only the transactions each test creates are uncategorized
    Transaction.where(id: @family.entries.where(entryable_type: "Transaction").select(:entryable_id), category_id: nil)
               .update_all(category_id: categories(:food_and_drink).id)
  end

  test "groups by merchant when there is one, whatever the names" do
    create_transaction(name: "NETFLIX.COM", merchant: merchants(:netflix))
    create_transaction(name: "Netflix Monthly", merchant: merchants(:netflix))

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "Netflix", groups.first.grouping_key
    assert_equal merchants(:netflix), groups.first.merchant
    assert groups.first.merchant_group?
    assert_equal 2, groups.first.entries.size
  end

  test "groups by exact name without a merchant" do
    create_transaction(name: "AMZN MKTP US")
    create_transaction(name: "AMZN MKTP US")
    create_transaction(name: "Bakery")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal [ "AMZN MKTP US", "Bakery" ], groups.map(&:grouping_key)
    assert_equal [ 2, 1 ], groups.map { |group| group.entries.size }
    assert_not groups.first.merchant_group?
  end

  test "splits a name into income and expense" do
    create_transaction(name: "Refund", amount: 50)
    create_transaction(name: "Refund", amount: -50)

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal %w[expense income], groups.map(&:transaction_type).sort
  end

  test "an inflow that is an investment contribution is an expense, as the rule type reads it" do
    create_transaction(name: "401k", amount: -100, kind: "investment_contribution")

    assert_equal "expense", Transaction::Grouper::ByMerchantOrName.call(@family.entries).sole.transaction_type
  end

  test "orders by size, then by name, and pages with offset and limit" do
    3.times { create_transaction(name: "Charlie") }
    2.times { create_transaction(name: "bravo") }
    2.times { create_transaction(name: "Alpha") }

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)
    assert_equal %w[Charlie Alpha bravo], groups.map(&:display_name)

    page = Transaction::Grouper::ByMerchantOrName.call(@family.entries, limit: 1, offset: 1)
    assert_equal %w[Alpha], page.map(&:display_name)
  end

  test "leaves out categorized, excluded, transfer and hidden-account transactions" do
    create_transaction(name: "Shop", category: categories(:food_and_drink))
    create_transaction(name: "Shop", excluded: true)
    create_transaction(name: "Shop", kind: "funds_movement")
    create_transaction(name: "Shop", kind: "cc_payment")
    loan_payment = create_transaction(name: "Shop", kind: "loan_payment")
    disabled = @family.accounts.create!(name: "Closed", balance: 0, currency: "USD", accountable: Depository.new, status: "disabled")
    create_transaction(name: "Shop", account: disabled)

    group = Transaction::Grouper::ByMerchantOrName.call(@family.entries).sole

    assert_equal [ loan_payment ], group.entries
  end

  test "only reads the entries it is given" do
    other_account = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    create_transaction(name: "Shop", account: other_account)

    assert_empty Transaction::Grouper::ByMerchantOrName.call(@family.entries)
  end

  test "total_money converts each amount and leaves out a currency with no rate" do
    usd = create_transaction(name: "Shop", amount: 10, currency: "USD")
    eur = create_transaction(name: "Shop", amount: -20, currency: "EUR")
    xyz = create_transaction(name: "Shop", amount: 5, currency: "JPY")
    ExchangeRate.expects(:rates_for).with(%w[USD EUR JPY], to: "USD").returns({ "USD" => 1, "EUR" => 1.5 })

    total = Transaction::Grouper.total_money([ usd, eur, xyz ], "USD")

    assert_equal Money.new(40, "USD"), total
  end
end
