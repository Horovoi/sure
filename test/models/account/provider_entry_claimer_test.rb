require "test_helper"

class Account::ProviderEntryClaimerTest < ActiveSupport::TestCase
  Row = Account::ProviderEntryClaimer::Row

  setup do
    travel_to Date.new(2026, 11, 15)
    @account = families(:empty).accounts.create!(name: "Card", balance: 0, currency: "UAH", accountable: Depository.new)
    @claimer = Account::ProviderEntryClaimer.new(@account, source: "monobank")
  end

  test "matches the same date and amount first" do
    near = manual(date: 1.day.ago, amount: 100)
    same = manual(date: Date.current, amount: 100)

    assert_equal({ "a" => same }, @claimer.match([ row("a", Date.current, 100) ]))
    assert_equal near, @claimer.match_one(row("b", 2.days.ago, 100))
  end

  test "matches up to three days away, closest first, then the oldest entry" do
    three_days = manual(date: 3.days.ago, amount: 50)
    older = manual(date: 1.day.ago, amount: 50, created_at: 2.hours.ago)
    newer = manual(date: 1.day.ago, amount: 50, created_at: 1.hour.ago)

    result = @claimer.match([ row("r1", Date.current, 50), row("r2", Date.current, 50), row("r3", Date.current, 50) ])

    assert_equal older, result["r1"]
    assert_equal newer, result["r2"]
    assert_equal three_days, result["r3"]
  end

  test "does not match four days away, another amount or the opposite sign" do
    manual(date: 4.days.ago, amount: 70)
    manual(date: Date.current, amount: 71)
    manual(date: Date.current, amount: -70)

    assert_empty @claimer.match([ row("x", Date.current, 70) ])
  end

  test "uses each entry and each row once" do
    entry = manual(date: Date.current, amount: 20)

    result = @claimer.match([ row("a", Date.current, 20), row("b", Date.current, 20) ])

    assert_equal({ "a" => entry }, result)
  end

  test "never claims an entry that has an external id or a provider claim" do
    manual(date: Date.current, amount: 30).update!(external_id: "tx-old", source: "monobank")
    claimed = manual(date: Date.current, amount: 30)
    claimed.transaction.update!(extra: { "provider_claim" => { "source" => "monobank" } })

    assert_empty @claimer.match([ row("new", Date.current, 30) ])
  end

  test "a pending row matches too (its entry is not handed to another row)" do
    entry = manual(date: Date.current, amount: 40)

    assert_equal({ "p" => entry }, @claimer.match([ row("p", Date.current, 40, pending: true), row("q", Date.current, 40) ]))
  end

  test "an entry from a manual source with an idempotency key is a candidate" do
    entry = manual(date: Date.current, amount: 44, source: "mcp", external_id: "chat-row-1")

    assert_equal entry, @claimer.match_one(row("x", Date.current, 44))
  end

  test "skips other currencies, generated subscription charges, excluded and pending entries" do
    manual(date: Date.current, amount: 40)
    manual(date: Date.current, amount: 41, source: "subscription")
    manual(date: Date.current, amount: 42, excluded: true)
    hold = manual(date: Date.current, amount: 43)
    hold.transaction.update!(extra: { "other" => { "pending" => true } })

    assert_empty @claimer.match([ row("c", Date.current, 40, currency: "USD") ])
    assert_empty @claimer.match([ row("s", Date.current, 41) ])
    assert_empty @claimer.match([ row("e", Date.current, 42) ])
    assert_empty @claimer.match([ row("h", Date.current, 43) ])
  end

  test "one query for the whole batch" do
    5.times { |i| manual(date: i.days.ago, amount: 10 + i) }
    rows = 5.times.map { |i| row("r#{i}", i.days.ago, 10 + i) }

    queries = count_entry_queries { @claimer.match(rows) }

    assert_equal 1, queries
  end

  private
    def row(key, date, amount, currency: "UAH", pending: false)
      Row.new(key: key, date: date.to_date, amount: amount.to_d, currency: currency, pending: pending)
    end

    def manual(date:, amount:, created_at: nil, source: nil, excluded: false, external_id: nil)
      attributes = { date: date.to_date, amount: amount, currency: "UAH", name: "Manual", source: source, excluded: excluded, external_id: external_id, entryable: Transaction.new }
      attributes[:created_at] = created_at if created_at
      @account.entries.create!(**attributes)
    end

    def count_entry_queries(&block)
      count = 0
      callback = ->(*, payload) { count += 1 if payload[:sql].include?("FROM \"entries\"") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      count
    end
end
