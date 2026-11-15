require "test_helper"

class Import::DuplicateMatcherTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository) # USD
    @import = imports(:transaction)
    # Default signage is inflows_positive: a "-50" row is a 50 outflow (entry amount 50)
    @import.update!(account: @account, date_format: "%m/%d/%Y")
  end

  test "matches an entry on the same date and amount, whatever its name" do
    entry = create_entry(date: Date.new(2024, 3, 10), amount: 50, name: "Typed by hand")
    row = create_row(date: "03/10/2024", amount: "-50", name: "CARD PAYMENT SILPO")

    assert_equal({ row.id => entry }, matches_for(row))
  end

  test "matches an entry up to 3 days away" do
    entry = create_entry(date: Date.new(2024, 3, 13), amount: 50)
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_equal({ row.id => entry }, matches_for(row))

    entry.update!(date: Date.new(2024, 3, 7))
    assert_equal({ row.id => entry }, matches_for(row))
  end

  test "does not match an entry 4 days away" do
    create_entry(date: Date.new(2024, 3, 14), amount: 50)
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_empty matches_for(row)
  end

  test "the closest date wins, then the oldest entry" do
    create_entry(date: Date.new(2024, 3, 12), amount: 50, name: "Two days")
    closest_newer = create_entry(date: Date.new(2024, 3, 11), amount: 50, name: "One day, newer")
    closest_older = create_entry(date: Date.new(2024, 3, 9), amount: 50, name: "One day, older")
    closest_older.update_column(:created_at, 1.day.ago)
    closest_newer.update_column(:created_at, 1.hour.ago)
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_equal closest_older, matches_for(row)[row.id]
  end

  test "an exact date beats a nearby one even for a later row" do
    nearby = create_entry(date: Date.new(2024, 3, 9), amount: 50)
    exact = create_entry(date: Date.new(2024, 3, 10), amount: 50)
    first = create_row(date: "03/08/2024", amount: "-50")
    second = create_row(date: "03/10/2024", amount: "-50")

    matches = matches_for(first, second)

    assert_equal exact, matches[second.id]
    assert_equal nearby, matches[first.id]
  end

  test "two same-amount rows against one entry give one match and one new row" do
    entry = create_entry(date: Date.new(2024, 3, 10), amount: 50)
    first = create_row(date: "03/10/2024", amount: "-50")
    second = create_row(date: "03/10/2024", amount: "-50")

    assert_equal({ first.id => entry }, matches_for(first, second))
  end

  test "a different sign is not a match" do
    create_entry(date: Date.new(2024, 3, 10), amount: -50) # an inflow
    row = create_row(date: "03/10/2024", amount: "-50") # an outflow

    assert_empty matches_for(row)
  end

  test "a different currency is not a match" do
    create_entry(date: Date.new(2024, 3, 10), amount: 50, currency: "EUR")
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_empty matches_for(row)

    # A row in another currency than the account is never matched
    @import.update!(currency_col_label: "currency")
    create_entry(date: Date.new(2024, 3, 10), amount: 50)
    eur_row = create_row(date: "03/10/2024", amount: "-50", currency: "EUR")

    assert_empty matches_for(eur_row)
  end

  test "a subscription-generated entry is matched" do
    entry = create_entry(date: Date.new(2024, 3, 10), amount: 9.99, name: "Netflix", source: "subscription")
    row = create_row(date: "03/11/2024", amount: "-9.99")

    assert_equal({ row.id => entry }, matches_for(row))
  end

  test "a provider entry is matched" do
    entry = create_entry(date: Date.new(2024, 3, 10), amount: 50, source: "plaid", external_id: "txn_1")
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_equal({ row.id => entry }, matches_for(row))
  end

  test "a row whose date or amount does not parse is offered" do
    create_entry(date: Date.new(2024, 3, 10), amount: 0)
    create_entry(date: Date.new(2024, 3, 10), amount: 50)
    bad_date = create_row(date: "10.03.2024", amount: "-50")
    bad_amount = create_row(date: "03/10/2024", amount: "fifty")

    assert_empty matches_for(bad_date, bad_amount)
  end

  test "the import's own entries, excluded entries and later entries are not candidates" do
    own = create_entry(date: Date.new(2024, 3, 10), amount: 50)
    own.update_column(:import_id, @import.id)
    claimed = create_entry(date: Date.new(2024, 3, 10), amount: 50)
    later = create_entry(date: Date.new(2024, 3, 10), amount: 50)
    later.update_column(:created_at, 1.hour.from_now)
    row = create_row(date: "03/10/2024", amount: "-50")

    matcher = Import::DuplicateMatcher.new(
      import: @import, account: @account, rows: [ row ],
      exclude_entry_ids: [ claimed.id ], created_before: Time.current
    )

    assert_empty matcher.matches
  end

  test "valuations and other accounts are not candidates" do
    @account.entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Balance", entryable: Valuation.new(kind: "reconciliation"))
    accounts(:credit_card).entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Other", entryable: Transaction.new)
    row = create_row(date: "03/10/2024", amount: "-50")

    assert_empty matches_for(row)
  end

  private
    def create_entry(date:, amount:, name: "Existing", currency: "USD", **attributes)
      @account.entries.create!(date: date, amount: amount, currency: currency, name: name, entryable: Transaction.new, **attributes)
    end

    def create_row(date:, amount:, name: "Statement row", currency: "USD")
      # Saved without validations, so rows that do not parse can be built too
      @import.rows.build(date: date, amount: amount, name: name, currency: currency).tap { |row| row.save!(validate: false) }
    end

    def matches_for(*rows)
      Import::DuplicateMatcher.new(import: @import, account: @account, rows: rows).matches
    end
end
