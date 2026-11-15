require "test_helper"

class MonobankAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  include MonobankTestHelper

  # Stands in for Mcc::CategoryMatcher (the mcc stream): records its calls
  class FakeMatcher
    attr_reader :calls

    def initialize(category)
      @category = category
      @calls = []
    end

    def category_for(**args)
      @calls << args
      args[:own_transfer] ? nil : @category
    end
  end

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
    @product = create_monobank_product(account_id: "card", balance: 100_000, iban: "UA0001")
    @account = @item.create_linked_account!(monobank_account: @product, accountable_type: "Depository")
    @groceries = @family.categories.create!(name: "Groceries Test", color: "#00ff00", classification: "expense")
  end

  teardown { travel_back }

  def process(rows, matcher: nil)
    @product.update!(raw_transactions_payload: rows)
    MonobankAccount::Transactions::Processor.new(@product.reload, category_matcher: matcher).process
  end

  def monobank_entries
    @account.entries.where(source: "monobank").order(:date)
  end

  test "books rows with Sure signs, the family's date, merchant, notes and metadata" do
    late_evening = Time.zone.parse("2026-11-14 22:30:00 UTC") # 00:30 on 15 Nov in Kyiv
    result = process([
      monobank_row(id: "out", time: late_evening, amount: -45_050, description: "Сільпо", comment: "for dinner", balance: 954_950),
      monobank_row(id: "in", time: 2.days.ago, amount: 100_000, description: "Від: Олена", mcc: 4829)
    ])

    assert_equal 2, result[:imported]
    out = @account.entries.find_by!(external_id: "monobank_out")
    assert_equal [ BigDecimal("450.5"), Date.new(2026, 11, 15), "Сільпо", "for dinner", "UAH" ], [ out.amount, out.date, out.name, out.notes, out.currency ]
    assert_equal "Сільпо", out.entryable.merchant.name
    assert_equal({ "pending" => false, "mcc" => 5411, "balance_after" => "9549.5" }, out.entryable.extra["monobank"].slice("pending", "mcc", "balance_after"))
    assert_equal(-1_000, @account.entries.find_by!(external_id: "monobank_in").amount)
  end

  test "a foreign operation stays in the account currency and keeps the operation currency" do
    process([ monobank_row(id: "fx", time: 1.day.ago, amount: -41_000, operationAmount: -1_000, currencyCode: 840) ])

    entry = monobank_entries.sole
    assert_equal [ "UAH", BigDecimal("410") ], [ entry.currency, entry.amount ]
    assert_equal({ "fx_from" => "USD", "fx_amount" => "-10.0" }, entry.entryable.extra["monobank"].slice("fx_from", "fx_amount"))
  end

  test "holds are pending; a released hold is removed, one the user worked on is kept" do
    process([ monobank_row(id: "hold-a", time: 1.day.ago, amount: -500, hold: true),
              monobank_row(id: "hold-b", time: 1.day.ago, amount: -700, hold: true) ])
    assert_equal 2, @account.entries.pending_from("monobank").count

    @account.entries.find_by!(external_id: "monobank_hold-b").update!(notes: "keep me")
    result = process([])

    assert_equal [ 1, 1 ], [ result[:pruned], result[:detached] ]
    kept = @account.entries.find_by!(external_id: "monobank_hold-b")
    assert_nil kept.entryable.extra.dig("monobank", "pending")
    assert_not @account.entries.exists?(external_id: "monobank_hold-a")
  end

  test "a hold that settles under the same id stops being pending" do
    process([ monobank_row(id: "h", time: 1.day.ago, amount: -500, hold: true) ])
    process([ monobank_row(id: "h", time: 1.day.ago, amount: -500, hold: false) ])

    entry = monobank_entries.sole
    assert_equal false, entry.entryable.extra.dig("monobank", "pending")
    assert_equal 0, @account.entries.pending_from("monobank").count
  end

  test "new settled rows take over hand-entered entries up to 3 days away, each entry once" do
    manual = add_manual_transaction(@account, date: 3.days.ago.to_date, amount: 450, name: "Silpo by hand")
    twin = add_manual_transaction(@account, date: 10.days.ago.to_date, amount: 99)

    result = process([
      monobank_row(id: "a", time: 1.day.ago, amount: -45_000),  # 2 days after the manual entry
      monobank_row(id: "b", time: 1.day.ago, amount: -45_000),  # same amount, nothing left to claim
      monobank_row(id: "c", time: 1.day.ago, amount: -9_900)    # 9 days away: too far
    ])

    assert_equal 1, result[:claimed]
    manual.reload
    assert_equal [ "monobank_a", "monobank", 3.days.ago.to_date, "Silpo by hand" ], [ manual.external_id, manual.source, manual.date, manual.name ]
    assert manual.entryable.extra["provider_claim"].present?
    assert_equal 3, monobank_entries.count
    assert_nil twin.reload.external_id

    assert_equal 0, process(@product.raw_transactions_payload)[:claimed], "a second pass claims nothing"
    assert_equal 3, monobank_entries.count
  end

  test "rows before the cutover are skipped unless they claim an entry" do
    Account::ProviderLink.unlink!(@account)
    add_manual_transaction(@account, date: Date.new(2026, 11, 13), amount: 200)
    link_product(@product, @account.reload, cutover_date: Date.new(2026, 11, 14))

    result = process([
      monobank_row(id: "claims", time: Time.zone.parse("2026-11-12 10:00 UTC"), amount: -20_000),
      monobank_row(id: "before", time: Time.zone.parse("2026-11-12 11:00 UTC"), amount: -1_234),
      monobank_row(id: "after", time: Time.zone.parse("2026-11-15 10:00 UTC"), amount: -500)
    ])

    assert_equal [ 1, 1 ], [ result[:claimed], result[:skipped_before_cutover] ]
    assert_equal %w[monobank_after monobank_claims].sort, monobank_entries.pluck(:external_id).sort
  end

  test "MCC categories go only to uncategorised entries, and never to own transfers" do
    matcher = FakeMatcher.new(@groceries)
    process([
      monobank_row(id: "shop", time: 1.day.ago, amount: -1_000, mcc: 5411),
      monobank_row(id: "to-jar", time: 1.day.ago, amount: -2_000, mcc: 4829, counterIban: "UA0001")
    ], matcher: matcher)

    assert_equal @groceries, @account.entries.find_by!(external_id: "monobank_shop").entryable.category
    assert_nil @account.entries.find_by!(external_id: "monobank_to-jar").entryable.category
    shop_call = matcher.calls.find { |call| call[:mcc] == 5411 }
    assert_equal({ mcc: 5411, original_mcc: 5411, amount: BigDecimal("10"), description: "Сільпо", own_transfer: false }, shop_call)
    assert matcher.calls.find { |call| call[:mcc] == 4829 }[:own_transfer]

    other = @family.categories.create!(name: "Chosen", color: "#ff0000", classification: "expense")
    @account.entries.find_by!(external_id: "monobank_shop").entryable.update!(category: other)
    process(@product.raw_transactions_payload, matcher: matcher)
    assert_equal other, @account.entries.find_by!(external_id: "monobank_shop").entryable.reload.category
  end

  test "no MCC matcher when the connection turns categorising off" do
    @item.update!(apply_mcc_categories: false)
    processor = MonobankAccount::Transactions::Processor.new(@product.reload)

    assert_nil processor.send(:category_matcher)
  end

  test "the mcc matcher is found by name when it exists" do
    skip "Mcc::CategoryMatcher is not loaded" unless "Mcc::CategoryMatcher".safe_constantize

    assert_kind_of Mcc::CategoryMatcher, MonobankAccount::Transactions::Processor.new(@product.reload).send(:category_matcher)
  end

  test "settled rows older than 35 days are dropped after a good pass; holds stay" do
    process([
      monobank_row(id: "old", time: 40.days.ago, amount: -100),
      monobank_row(id: "old-hold", time: 30.days.ago, amount: -100, hold: true),
      monobank_row(id: "recent", time: 2.days.ago, amount: -100)
    ])

    assert_equal %w[old-hold recent], @product.reload.raw_transactions_payload.map { |row| row["id"] }.sort
    assert @account.entries.exists?(external_id: "monobank_old")
  end

  test "a row that fails is kept for the next pass and reported" do
    rows = [ monobank_row(id: "bad", time: 40.days.ago, amount: -100), monobank_row(id: "ok", time: 40.days.ago, amount: -100) ]
    rows[0]["time"] = nil

    result = process(rows)

    assert_equal 1, result[:failed]
    assert_equal 2, @product.reload.raw_transactions_payload.size
  end
end
