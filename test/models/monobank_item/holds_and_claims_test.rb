require "test_helper"

# Holds (pending rows) against hand-entered entries, settling, releasing and re-reading
# stored rows, through processing and the balance syncs.
class MonobankItem::HoldsAndClaimsTest < ActiveSupport::TestCase
  include MonobankTestHelper
  include ActiveJob::TestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC") # 14:00 on 16 Nov in Kyiv
    setup_monobank_family
  end

  teardown { travel_back }

  def book!
    @item.reload.process_accounts.each { |result| assert result[:success], result.inspect }
    @item.accounts.reload.each { |account| account.sync_later }
    perform_enqueued_jobs(only: SyncJob)
  end

  def store(product, rows, balance: nil)
    attributes = { raw_transactions_payload: rows }
    attributes[:raw_balance_minor] = balance if balance
    product.update!(attributes)
  end

  def kyiv(time)
    Time.find_zone("Europe/Kyiv").parse(time)
  end

  def hand_kept_account(name: "Mono Black")
    account = create_sure_account(name: name)
    Account::OpeningBalanceManager.new(account).set_opening_balance(balance: 1_000, date: Date.new(2026, 10, 31))
    account
  end

  def transactions_of(account, amount)
    account.entries.where(entryable_type: "Transaction", amount: amount).order(:date)
  end

  test "a hold of a hand entry on the cut-over day is not booked, and its settled row claims the entry" do
    account = hand_kept_account
    coffee = add_manual_transaction(account, date: Date.new(2026, 11, 16), amount: 50, name: "Coffee by hand")
    card = create_monobank_product(account_id: "card", balance: 95_000)
    @item.link_existing_account!(monobank_account: card, account: account)
    assert_equal Date.new(2026, 11, 16), account.reload.provider_cutover_date

    store(card, [ monobank_row(id: "h1", time: kyiv("2026-11-16 10:00"), amount: -5_000, hold: true, description: "Aroma Kava") ])
    book!
    assert_equal [ coffee.id ], transactions_of(account, 50).ids
    assert_nil coffee.reload.external_id

    store(card, [ monobank_row(id: "h1", time: kyiv("2026-11-16 10:00"), amount: -5_000, hold: false, description: "Aroma Kava") ])
    book!

    assert_equal [ coffee.id ], transactions_of(account, 50).ids
    coffee.reload
    assert_equal [ "monobank_h1", "monobank", "Coffee by hand" ], [ coffee.external_id, coffee.source, coffee.name ]
  end

  test "a posted row never takes the hand entry a hold stands for" do
    account = hand_kept_account
    old_coffee = add_manual_transaction(account, date: Date.new(2026, 11, 15), amount: 50, name: "Coffee")
    lunch = add_manual_transaction(account, date: Date.new(2026, 11, 16), amount: 120, name: "Lunch")
    card = create_monobank_product(account_id: "card", balance: 100_000)
    @item.link_existing_account!(monobank_account: card, account: account)
    assert_equal Date.new(2026, 11, 16), account.reload.provider_cutover_date

    rows = [
      monobank_row(id: "coffee-y", time: kyiv("2026-11-15 10:00"), amount: -5_000, hold: true),
      monobank_row(id: "coffee-today", time: kyiv("2026-11-16 09:00"), amount: -5_000),
      monobank_row(id: "lunch", time: kyiv("2026-11-16 11:00"), amount: -12_000)
    ]
    store(card, rows)
    book!

    assert_equal "monobank_lunch", lunch.reload.external_id
    assert_nil old_coffee.reload.external_id, "kept for the hold"
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 16) ], transactions_of(account, 50).pluck(:date)

    rows[0] = rows[0].merge("hold" => false)
    store(card, rows)
    book!

    assert_equal "monobank_coffee-y", old_coffee.reload.external_id
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 16) ], transactions_of(account, 50).pluck(:date)
  end

  test "a hold booked before the hand entry was made is replaced by it when it settles" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "h2", time: 1.day.ago, amount: -7_000, hold: true) ])
    book!
    assert_equal 1, account.entries.pending_from("monobank").count

    manual = add_manual_transaction(account, date: 1.day.ago.to_date, amount: 70, name: "Pharmacy by hand")
    book!
    assert_nil manual.reload.external_id, "still a hold"

    store(card, [ monobank_row(id: "h2", time: 1.day.ago, amount: -7_000, hold: false) ])
    book!

    assert_equal [ manual.id ], transactions_of(account, 70).ids
    assert_equal "monobank_h2", manual.reload.external_id
  end

  test "a hold the user renamed still gets the settled amount and stops being pending" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "fx", time: 1.day.ago, amount: -41_000, hold: true, operationAmount: -1_000, currencyCode: 840) ])
    book!
    hold = account.entries.find_by!(external_id: "monobank_fx")
    hold.update!(name: "Steam game")
    hold.mark_user_modified!

    store(card, [ monobank_row(id: "fx", time: 1.day.ago, amount: -41_500, hold: false, operationAmount: -1_000, currencyCode: 840) ], balance: 58_500)
    book!

    hold.reload
    assert_equal [ BigDecimal("415"), "Steam game", false ], [ hold.amount, hold.name, hold.transaction.pending? ]
    assert_equal 1_000, account.reload.balances.find_by!(date: 3.days.ago.to_date).end_balance
  end

  test "a released hold the user only categorised is removed; one with a note counts nowhere" do
    card = create_monobank_product(account_id: "card", balance: 88_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "cat", time: 3.days.ago, amount: -5_000, hold: true),
                  monobank_row(id: "note", time: 3.days.ago, amount: -7_000, hold: true) ])
    book!
    categorised = account.entries.find_by!(external_id: "monobank_cat")
    categorised.transaction.update!(category: categories(:food_and_drink))
    categorised.mark_user_modified!
    noted = account.entries.find_by!(external_id: "monobank_note")
    noted.update!(notes: "dinner")

    store(card, [], balance: 100_000) # both holds cancelled
    book!

    assert_not Entry.exists?(categorised.id)
    assert Entry.exists?(noted.id)
    account.reload
    assert_equal 1_000, account.balance
    assert_equal 1_000, account.balances.find_by!(date: 5.days.ago.to_date).end_balance
    assert_not_includes account.entries.excluding_pending, noted
  end

  test "with holds turned off, the balance leaves them out so the history stays right" do
    @item.update!(include_pending: false)
    card = create_monobank_product(account_id: "card", balance: 95_000) # 1000 before the 50 hold
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "h", time: 3.days.ago, amount: -5_000, hold: true) ])

    book!

    account.reload
    assert_equal 0, account.entries.where(source: "monobank").count
    assert_equal 1_000, account.balance
    assert_equal 1_000, account.balances.find_by!(date: 5.days.ago.to_date).end_balance
  end

  test "re-reading stored rows keeps a converted merchant and a rule-set name" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "s", time: 1.day.ago, amount: -1_000, description: "SILPO 123 KYIV") ])
    book!
    entry = account.entries.find_by!(external_id: "monobank_s")
    family_merchant = entry.transaction.merchant.convert_to_family_merchant_for(@family, name: "Silpo")
    entry.enrich_attribute(:name, "Silpo", source: "rule")

    book!

    entry.reload
    assert_equal [ "Silpo", family_merchant.id ], [ entry.name, entry.transaction.merchant_id ]
  end

  test "a new settled row never takes over or flags another purchase's hold" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "coffee-1", time: 1.day.ago, amount: -7_000, hold: true, description: "Aroma Kava"),
                  monobank_row(id: "coffee-2", time: 1.day.ago, amount: -5_000, hold: true, description: "Aroma Kava") ])
    book!

    store(card, card.raw_transactions_payload + [
      monobank_row(id: "coffee-3", time: 2.hours.ago, amount: -8_000, description: "Aroma Kava"),
      monobank_row(id: "coffee-4", time: 2.hours.ago, amount: -5_000, description: "Aroma Kava")
    ])
    book!

    first = account.entries.find_by!(external_id: "monobank_coffee-1")
    second = account.entries.find_by!(external_id: "monobank_coffee-2")
    assert first.transaction.pending?
    assert second.transaction.pending?
    assert_not first.transaction.has_potential_duplicate?
    assert_equal 4, account.entries.where(source: "monobank").count
  end

  test "an entry made through the assistant with an idempotency key is claimed" do
    account = hand_kept_account
    mcp = add_manual_transaction(account, date: Date.new(2026, 11, 16), amount: 50, name: "Coffee (chat)", source: "mcp", external_id: "chat-row-1")
    card = create_monobank_product(account_id: "card", balance: 95_000)
    @item.link_existing_account!(monobank_account: card, account: account)

    store(card, [ monobank_row(id: "c", time: kyiv("2026-11-16 10:00"), amount: -5_000) ])
    book!

    assert_equal [ mcp.id ], transactions_of(account, 50).ids
    assert_equal "monobank_c", mcp.reload.external_id
  end

  test "a category guessed from the MCC gives way to Investment Contributions when the transfer is confirmed" do
    contributions = @family.investment_contributions_category ||
      @family.categories.create!(name: Category.investment_contributions_name, color: "#00aaff", classification: "expense")
    p2p = @family.categories.create!(name: "P2P Outgoing Test", color: "#ff00aa", classification: "expense")
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "ibkr", time: 1.day.ago, amount: -50_000, description: "Переказ на картку IBKR", mcc: 4829) ])
    MonobankAccount::Transactions::Processor.new(card.reload, category_matcher: Struct.new(:category) { def category_for(**) = category }.new(p2p)).process
    outflow = account.entries.find_by!(external_id: "monobank_ibkr").transaction
    assert_equal p2p, outflow.category
    assert outflow.category_guessed?

    investment = @family.accounts.create!(name: "IBKR", balance: 0, currency: "UAH", accountable: Investment.new)
    inflow = investment.entries.create!(date: 1.day.ago.to_date, amount: -500, currency: "UAH", name: "Deposit", entryable: Transaction.new).transaction
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, status: "pending").confirm!

    outflow.reload
    assert_equal "investment_contribution", outflow.kind
    assert_equal contributions, outflow.category
  end
  test "unlinking with an open hold keeps the history and makes the hold an ordinary entry" do
    card = create_monobank_product(account_id: "card", balance: 97_000) # 1000 before the 30 hold
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "h", time: 4.days.ago, amount: -3_000, hold: true) ])
    book!
    before = account.reload.balances.where(date: 6.days.ago.to_date..Date.current).order(:date).pluck(:date, :end_balance)

    Account::ProviderLink.unlink!(account)
    perform_enqueued_jobs(only: SyncJob)

    hold = account.entries.find_by!(external_id: "monobank_h")
    assert_not hold.transaction.pending?
    assert_equal before, account.reload.balances.where(date: 6.days.ago.to_date..Date.current).order(:date).pluck(:date, :end_balance)
  end

  test "with monobank switched off, a linked account syncs forward so new hand entries count" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "s", time: 3.days.ago, amount: -1_000) ])
    book!
    assert_equal 1_000, account.reload.balance

    BankConnections.stubs(:enabled_keys).returns(Set.new)
    travel 2.days
    add_manual_transaction(account, date: Date.current, amount: 100, name: "Cash")
    account.sync_later
    perform_enqueued_jobs(only: SyncJob)

    account.reload
    assert_equal :forward, account.balance_strategy
    assert_equal 900, account.balance
  end

  test "a pending hold is no occurrence for subscription detection" do
    card = create_monobank_product(account_id: "card", balance: 100_000)
    account = @item.create_linked_account!(monobank_account: card)
    store(card, [ monobank_row(id: "netflix", time: 1.day.ago, amount: -29_900, hold: true, description: "Netflix") ])
    book!

    hold = account.entries.find_by!(external_id: "monobank_netflix")
    assert_not_includes RecurringTransaction.recurring_entries_for(@family), hold
  end
end
