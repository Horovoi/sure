require "test_helper"

class MonobankAccount::ProcessorTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
  end

  teardown { travel_back }

  def process(product)
    MonobankAccount::Processor.new(product.reload).process
  end

  test "a credit card gets its debt as the balance and the available funds as available credit" do
    product = create_monobank_product(account_id: "card", balance: 4_200_000, credit_limit: 5_000_000)
    account = @item.create_linked_account!(monobank_account: product)

    process(product)

    account.reload
    assert_equal 8_000, account.balance
    assert_equal 42_000, account.accountable.available_credit
    assert_equal 8_000, account.current_anchor_balance
    assert_equal Date.current, account.current_anchor_date
  end

  test "a card linked as a cash account gets its own funds" do
    product = create_monobank_product(account_id: "card", balance: 4_200_000, credit_limit: 5_000_000)
    account = @item.create_linked_account!(monobank_account: product, accountable_type: "Depository")

    process(product)

    assert_equal(-8_000, account.reload.balance)
  end

  test "currency accounts, jars and FOP accounts get their balance in their currency" do
    usd = create_monobank_product(account_id: "usd", currency: "USD", balance: 12_345)
    eur = create_monobank_product(account_id: "eur", currency: "EUR", balance: 50)
    jar = create_monobank_product(account_id: "jar", kind: "jar", title: "Відпустка", balance: 150_000, goal: 2_000_000)
    fop = create_monobank_product(account_id: "fop", type: "fop", balance: 1_000_000)
    accounts = [ usd, eur, jar, fop ].to_h { |product| [ product, @item.create_linked_account!(monobank_account: product) ] }

    accounts.each_key { |product| process(product) }

    assert_equal [ "USD", BigDecimal("123.45") ], [ accounts[usd].reload.currency, accounts[usd].balance ]
    assert_equal [ "EUR", BigDecimal("0.5") ], [ accounts[eur].reload.currency, accounts[eur].balance ]
    assert_equal 1_500, accounts[jar].reload.balance
    assert_equal 10_000, accounts[fop].reload.balance
  end

  test "nothing for an unlinked product" do
    assert_nil process(create_monobank_product(account_id: "card"))
  end

  test "once the backfill is complete the opening anchor is the balance before the oldest row" do
    product = create_monobank_product(account_id: "card", balance: 70_000)
    account = @item.create_linked_account!(monobank_account: product)
    product.update!(
      history_complete: true,
      raw_transactions_payload: [
        monobank_row(id: "new", time: 2.days.ago, amount: -10_000, balance: 70_000),
        monobank_row(id: "old", time: 20.days.ago, amount: -20_000, balance: 80_000), # 1000 before it
        monobank_row(id: "old-later", time: 20.days.ago + 1.hour, amount: 0, balance: 80_000)
      ]
    )

    process(product)

    assert_equal 1_000, account.reload.opening_anchor_balance
    assert product.reload.opening_anchor_set_at.present?

    product.update!(raw_transactions_payload: [])
    process(product)
    assert_equal 1_000, account.reload.opening_anchor_balance, "set once"
  end

  test "a hand-kept account keeps its own opening anchor" do
    product = create_monobank_product(account_id: "card", balance: 70_000)
    account = create_sure_account(name: "Card", balance: 500)
    add_manual_transaction(account, date: 5.days.ago.to_date, amount: 10)
    @item.link_existing_account!(monobank_account: product, account: account)
    product.update!(history_complete: true)
    before = account.reload.opening_anchor_balance

    process(product)

    assert_equal before, account.reload.opening_anchor_balance
    assert_nil product.reload.opening_anchor_set_at
  end
end
