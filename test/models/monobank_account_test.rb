require "test_helper"

class MonobankAccountTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup { setup_monobank_family }

  test "suggested types: credit card with a limit, cash without, savings for jars, ask for unknown" do
    assert_equal "CreditCard", create_monobank_product(account_id: "a", credit_limit: 100).suggested_account_type
    assert_equal "Depository", create_monobank_product(account_id: "b").suggested_account_type
    assert_equal "Depository", create_monobank_product(account_id: "c", type: "fop").suggested_account_type
    assert_equal "savings", create_monobank_product(account_id: "d", kind: "jar", title: "Jar").suggested_subtype
    assert_nil create_monobank_product(account_id: "e", type: "madeup").suggested_account_type
  end

  test "balance_for: debt for a credit card, own funds for cash" do
    product = create_monobank_product(account_id: "a", balance: 6_000_000, credit_limit: 5_000_000)

    assert_equal(-10_000, product.balance_for("CreditCard"), "own money above the limit is a negative debt")
    assert_equal 10_000, product.balance_for("Depository")
  end

  test "unknown products have no balance until client-info reports one" do
    product = @item.monobank_accounts.create!(account_id: "x", name: "x", currency: "UAH", account_kind: "card")
    assert_nil product.balance_for("Depository")
  end

  test "suggest_links proposes the hand-kept Mono card for the UAH credit card only" do
    visa = create_sure_account(name: "Mono Visa", accountable_type: "CreditCard")
    cash = create_sure_account(name: "Mono cash")
    other = create_sure_account(name: "Wallet")
    credit = create_monobank_product(account_id: "uah", credit_limit: 1_000_00)
    usd = create_monobank_product(account_id: "usd", currency: "USD")

    links = MonobankAccount.suggest_links([ usd, credit ], [ visa, cash, other ])

    assert_equal({ credit.id => visa }, links)
  end

  test "an account is unique per connection" do
    create_monobank_product(account_id: "a")
    assert_raises(ActiveRecord::RecordInvalid) do
      @item.monobank_accounts.create!(account_id: "a", name: "dup", currency: "UAH", account_kind: "card")
    end
  end
end
