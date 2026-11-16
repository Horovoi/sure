require "test_helper"

# A split monobank transaction (Entry::Splittable) through later syncs: the parent stays
# the bank's row, nothing undoes or duplicates the split, and holds cannot be split.
class MonobankAccount::Transactions::SplitSyncTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
    @product = create_monobank_product(account_id: "card", balance: 100_000, iban: "UA0001")
    @account = @item.create_linked_account!(monobank_account: @product, accountable_type: "Depository")
  end

  teardown { travel_back }

  test "a re-sync keeps the split and books nothing twice" do
    rows = [ monobank_row(id: "silpo", time: 1.day.ago, amount: -100_000, description: "Сільпо") ]
    process(rows)
    entry = @account.entries.find_by!(external_id: "monobank_silpo")

    entry.split!([ { name: "Food", amount: 700 }, { name: "Home", amount: 300 } ])

    # The bank sends the same row again, also with another description
    process(rows)
    process([ monobank_row(id: "silpo", time: 1.day.ago, amount: -100_000, description: "Silpo renamed") ])

    entry.reload
    assert entry.split_parent?
    assert entry.excluded?
    assert_equal "Сільпо", entry.name
    assert_equal [ 700, 300 ], entry.child_entries.map(&:amount)
    assert_equal 1, @account.entries.where(external_id: "monobank_silpo").count
    assert_equal 3, @account.entries.count { |e| e.transaction? }
  end

  test "a hold cannot be split, and a split survives a later hold of the same amount" do
    process([ monobank_row(id: "hold", time: 1.day.ago, amount: -50_000, hold: true) ])
    hold = @account.entries.find_by!(external_id: "monobank_hold")
    assert_equal :pending, hold.split_blocker

    process([ monobank_row(id: "hold", time: 1.day.ago, amount: -50_000, hold: false) ])
    posted = hold.reload
    assert posted.splittable?
    posted.split!([ { amount: 250 }, { amount: 250 } ])

    # A new hold of the same amount is a new purchase: it never claims a part
    process([
      monobank_row(id: "hold", time: 1.day.ago, amount: -50_000, hold: false),
      monobank_row(id: "hold2", time: Time.current, amount: -25_000, hold: true)
    ])
    assert_equal 2, posted.reload.child_entries.count
    assert posted.child_entries.all? { |child| child.external_id.nil? && child.source.nil? }
  end

  test "linking monobank claims a split manual transaction as a whole, not one of its parts" do
    manual_account = create_sure_account(name: "Cash card")
    manual = add_manual_transaction(manual_account, date: 1.day.ago.to_date, amount: 400, name: "Market")
    manual.split!([ { amount: 400 - 150 }, { amount: 150 } ])

    product = create_monobank_product(account_id: "card2", balance: 0, iban: "UA0002")
    link_product(product, manual_account)

    product.update!(raw_transactions_payload: [ monobank_row(id: "m1", time: 1.day.ago, amount: -40_000), monobank_row(id: "m2", time: 1.day.ago, amount: -15_000) ])
    MonobankAccount::Transactions::Processor.new(product.reload).process

    manual.reload
    assert_equal "monobank_m1", manual.external_id, "the bank's row takes over the split transaction"
    assert manual.split_parent?
    assert manual.child_entries.all? { |child| child.external_id.nil? }, "no part is claimed"
    assert manual_account.entries.exists?(external_id: "monobank_m2"), "a row matching only a part is booked on its own"
  end

  private
    def process(rows)
      @product.update!(raw_transactions_payload: rows)
      MonobankAccount::Transactions::Processor.new(@product.reload).process
    end
end
