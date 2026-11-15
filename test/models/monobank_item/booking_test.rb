require "test_helper"

# A connection's rows through processing, balance syncs and the family steps:
# balances, cut-over history and transfers between products.
class MonobankItem::BookingTest < ActiveSupport::TestCase
  include MonobankTestHelper
  include ActiveJob::TestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
  end

  teardown { travel_back }

  def book!
    @item.reload.process_accounts.each { |result| assert result[:success], result.inspect }
    @item.accounts.reload.each { |account| account.sync_later }
    perform_enqueued_jobs(only: SyncJob)
  end

  test "a hand-kept credit card linked at a cut-over keeps its history and ends at monobank's balance" do
    visa = create_sure_account(name: "Mono Visa", accountable_type: "CreditCard", balance: 0)
    Account::OpeningBalanceManager.new(visa).set_opening_balance(balance: 1_000, date: Date.new(2026, 10, 31))
    add_manual_transaction(visa, date: Date.new(2026, 11, 5), amount: 300, name: "Groceries")
    add_manual_transaction(visa, date: Date.new(2026, 11, 13), amount: 200, name: "Taxi")
    visa.sync_later
    perform_enqueued_jobs(only: SyncJob)
    before = visa.balances.where(date: ..Date.new(2026, 11, 13)).order(:date).pluck(:date, :end_balance)
    assert_equal 1_500, visa.reload.balance

    card = create_monobank_product(account_id: "card", balance: 4_830_000, credit_limit: 5_000_000) # debt 1700
    @item.link_existing_account!(monobank_account: card, account: visa)
    assert_equal Date.new(2026, 11, 14), visa.reload.provider_cutover_date
    card.update!(raw_transactions_payload: [
      monobank_row(id: "taxi", time: Time.zone.parse("2026-11-12 20:00 UTC"), amount: -20_000, description: "Uklon"),  # claims "Taxi"
      monobank_row(id: "early", time: Time.zone.parse("2026-11-12 08:00 UTC"), amount: -5_000),                          # before cut-over
      monobank_row(id: "coffee", time: Time.zone.parse("2026-11-15 08:00 UTC"), amount: -20_000, description: "Aroma Kava")
    ])

    book!

    visa.reload
    assert_equal 1_700, visa.balance
    assert_equal :cutover, visa.balance_strategy
    assert_equal before, visa.balances.where(date: ..Date.new(2026, 11, 13)).order(:date).pluck(:date, :end_balance)
    assert_equal 1_700, visa.balances.find_by!(date: Date.current).end_balance
    assert_equal %w[Aroma\ Kava Groceries Taxi].sort, visa.entries.where(entryable_type: "Transaction").pluck(:name).sort
  end

  test "card to jar and back are suggested as transfers and not categorised" do
    card = create_monobank_product(account_id: "card", balance: 90_000, iban: "UA0001")
    jar = create_monobank_product(account_id: "jar", kind: "jar", title: "Відпустка", balance: 10_000)
    card_account = @item.create_linked_account!(monobank_account: card)
    jar_account = @item.create_linked_account!(monobank_account: jar)
    card.update!(raw_transactions_payload: [ monobank_row(id: "c1", time: 1.day.ago, amount: -10_000, description: "На банку", mcc: 4829) ])
    jar.update!(raw_transactions_payload: [ monobank_row(id: "j1", time: 1.day.ago, amount: 10_000, description: "З картки", mcc: 4829) ])

    book!
    Family::ProviderPostSync.new(@family).run

    outflow = card_account.entries.find_by!(external_id: "monobank_c1").entryable
    inflow = jar_account.entries.find_by!(external_id: "monobank_j1").entryable
    transfer = Transfer.find_by(outflow_transaction: outflow, inflow_transaction: inflow)
    assert transfer, "a transfer suggestion between the card and the jar"
    assert_nil outflow.reload.category
    assert_equal 900, card_account.reload.balance
    assert_equal 100, jar_account.reload.balance
  end

  test "an open hold counts in the balance history like monobank counts it" do
    card = create_monobank_product(account_id: "card", balance: 95_000) # 1000 before the 50 hold
    account = @item.create_linked_account!(monobank_account: card)
    card.update!(raw_transactions_payload: [ monobank_row(id: "h", time: 1.day.ago, amount: -5_000, hold: true) ])

    book!

    account.reload
    assert_equal 950, account.balance
    assert_equal 1_000, account.balances.find_by!(date: 2.days.ago.to_date).end_balance
  end
end
