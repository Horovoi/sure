require "test_helper"

class Entry::SplittableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @food = categories(:food_and_drink)
    @other = categories(:subscriptions)
    @entry = create_transaction(account: @account, name: "Supermarket", amount: 100, merchant: merchants(:amazon))
  end

  test "split creates children that sum to the parent and takes the parent out of the figures" do
    children = @entry.split!([
      { name: "Groceries", amount: 60, category_id: @food.id },
      { name: "Household", amount: 40, category_id: @other.id, notes: "Soap", tag_ids: [ tags(:one).id ], excluded: "1" }
    ])

    @entry.reload
    assert @entry.split_parent?
    assert @entry.excluded?
    assert @entry.user_modified?
    assert_equal 2, @entry.child_entries.count
    assert_equal 100, @entry.split_total

    groceries, household = children
    assert groceries.split_child?
    assert_equal @entry, groceries.parent_entry
    assert_equal @entry.date, groceries.date
    assert_equal @account, groceries.account
    assert_equal "USD", groceries.currency
    assert_equal @food, groceries.transaction.category
    assert_equal merchants(:amazon), groceries.transaction.merchant, "a part keeps the parent's merchant unless one is given"
    assert_not groceries.excluded?
    assert household.excluded?
    assert_equal "Soap", household.notes
    assert_equal [ tags(:one) ], household.transaction.tags.to_a
    assert groceries.transaction.locked?(:category_id), "a part's category is kept from rules"
  end

  test "split refuses parts that do not add up, a single part or a zero part" do
    assert_raises(ActiveRecord::RecordInvalid) { @entry.split!([ { amount: 60 }, { amount: 30 } ]) }
    assert_raises(ActiveRecord::RecordInvalid) { @entry.split!([ { amount: 100 } ]) }
    assert_raises(ActiveRecord::RecordInvalid) { @entry.split!([ { amount: 100 }, { amount: 0 } ]) }
    assert_raises(ActiveRecord::RecordInvalid) { @entry.split!([ { amount: "abc" }, { amount: 100 } ]) }

    assert_not @entry.reload.split_parent?
    assert_not @entry.excluded?
  end

  test "a part may go the other way as long as the parts sum to the parent" do
    @entry.split!([ { name: "Shoes", amount: 130 }, { name: "Gift card refund", amount: -30 } ])
    assert_equal [ 130, -30 ], @entry.reload.child_entries.map(&:amount)
  end

  test "what cannot be split" do
    @entry.split!([ { amount: 50 }, { amount: 50 } ])
    child = @entry.child_entries.first

    assert_equal :already_split, @entry.reload.split_blocker
    assert_equal :split_child, child.split_blocker
    assert_raises(Entry::Splittable::NotSplittable) { @entry.split!([ { amount: 50 }, { amount: 50 } ]) }

    excluded = create_transaction(amount: 20, excluded: true)
    assert_equal :excluded, excluded.split_blocker

    transfer_leg = entries(:transfer_out)
    assert_equal :transfer, transfer_leg.split_blocker

    pending = create_transaction(amount: 20)
    pending.transaction.update!(extra: { "monobank" => { "pending" => true } })
    assert_equal :pending, pending.reload.split_blocker

    generated = create_transaction(amount: 20, source: "subscription")
    assert_equal :generated_charge, generated.split_blocker

    assert_equal :not_transaction, entries(:valuation).split_blocker
  end

  test "a part's amount and date, and the parent's amount and excluded flag, are fixed while split" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    child = @entry.child_entries.first

    assert_not child.update(amount: 10)
    assert_not child.reload.update(date: 3.days.ago.to_date)
    assert_not @entry.reload.update(amount: 120)
    assert_not @entry.reload.update(excluded: false)

    # The descriptive fields of a part stay editable
    assert child.reload.update(name: "Renamed", notes: "n", excluded: true)
  end

  test "a part cannot be deleted on its own; deleting the parent deletes its parts" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    child = @entry.child_entries.first

    assert_not child.destroy
    assert Entry.exists?(child.id)

    child_txn_ids = @entry.child_entries.map(&:entryable_id)
    @entry.reload.destroy!
    assert_equal 0, Entry.where(parent_entry_id: @entry.id).count
    assert_equal 0, Transaction.where(id: child_txn_ids).count
  end

  test "moving the parent's date moves its parts" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    new_date = 5.days.ago.to_date

    @entry.reload.update!(date: new_date)
    assert_equal [ new_date ], @entry.child_entries.reload.map(&:date).uniq
  end

  test "resplit updates parts in place, adds new ones and removes the rest" do
    first, second = @entry.split!([ { name: "A", amount: 70 }, { name: "B", amount: 30 } ])
    first.update!(notes: "kept note")

    @entry.reload.resplit!([
      { id: first.id, name: "A2", amount: 50 },
      { name: "C", amount: 50, category_id: @food.id }
    ])

    children = @entry.reload.child_entries.to_a
    assert_equal 2, children.size
    assert_equal first.id, children.first.id
    assert_equal "A2", children.first.name
    assert_equal 50, children.first.amount
    assert_equal "kept note", children.first.notes, "a field the editor leaves out stays"
    assert_not Entry.exists?(second.id)
    assert_equal @food, children.last.transaction.category
  end

  test "unsplit removes the parts and puts the parent back" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    @entry.reload.unsplit!

    @entry.reload
    assert_not @entry.split_parent?
    assert_not @entry.excluded?
    assert @entry.splittable?
    assert_raises(Entry::Splittable::NotSplittable) { @entry.unsplit! }
  end

  test "scopes keep balance rows and list rows apart" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    ids = @account.entries.pluck(:id)
    child_ids = @entry.child_entries.pluck(:id)

    assert_empty @account.entries.excluding_split_children.where(id: child_ids)
    assert_includes @account.entries.excluding_split_children.pluck(:id), @entry.id
    assert_not_includes @account.entries.excluding_split_parents.pluck(:id), @entry.id
    assert_equal child_ids.sort, @account.entries.excluding_split_parents.where(id: child_ids).pluck(:id).sort
    assert_equal Set[@entry.id], Entry.split_parent_ids_among(ids)
  end

  test "a split transaction or a part of one cannot become a transfer leg" do
    @entry.split!([ { amount: 70 }, { amount: 30 } ])
    inflow = create_transaction(account: accounts(:credit_card), amount: -70, currency: "USD")

    transfer = Transfer.new(inflow_transaction: inflow.transaction, outflow_transaction: @entry.child_entries.first.transaction)
    assert_not transfer.valid?

    inflow100 = create_transaction(account: accounts(:credit_card), amount: -100, currency: "USD")
    transfer = Transfer.new(inflow_transaction: inflow100.transaction, outflow_transaction: @entry.reload.transaction)
    assert_not transfer.valid?
  end
  test "rules act on the parts, never on the split parent, and keep what the user picked" do
    picked, open_part = @entry.split!([ { name: "Supermarket", amount: 60, category_id: @food.id }, { name: "Supermarket", amount: 40 } ])
    groceries = @family.categories.create!(name: "Rule groceries")

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Supermarket") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: groceries.id) ]
    )
    assert_not_includes rule.registry.resource_scope.map(&:id), @entry.entryable_id

    rule.apply

    assert_equal groceries, open_part.reload.transaction.category, "the part left uncategorized gets the rule's category"
    assert_equal @food, picked.reload.transaction.category, "the part's category the user picked is kept"
    assert_nil @entry.reload.transaction.category_id, "the parent is not touched"
  end
  test "a part finer than the stored 4 decimals is refused, and an id given twice names one part" do
    assert_raises(ActiveRecord::RecordInvalid) { @entry.split!([ { amount: "50.00001" }, { amount: "49.99999" } ]) }

    first, = @entry.split!([ { amount: 50 }, { amount: 50 } ])
    @entry.reload.resplit!([ { id: first.id, amount: 30 }, { id: first.id, amount: 70 } ])

    assert_equal [ 30, 70 ], @entry.reload.child_entries.map(&:amount)
    assert_equal 100, @entry.split_total
  end

  test "deleting the account deletes the split with its parts" do
    @entry.split!([ { amount: 50 }, { amount: 50 } ])
    ids = [ @entry.id, *@entry.child_entries.pluck(:id) ]

    @account.destroy!
    assert_equal 0, Entry.where(id: ids).count
  end
  test "a part counts as attached when its parent holds the receipt" do
    @entry.transaction.attachments.attach(io: StringIO.new("%PDF-1.4 receipt"), filename: "receipt.pdf", content_type: "application/pdf")
    child_txn_ids = @entry.split!([ { amount: 50 }, { amount: 50 } ]).map(&:entryable_id)

    with = Transaction::Search.new(@family, filters: { "attachment_status" => [ "with" ] }).transactions_scope.pluck(:id)
    without = Transaction::Search.new(@family, filters: { "attachment_status" => [ "without" ] }).transactions_scope.pluck(:id)

    assert_empty child_txn_ids - with
    assert_empty child_txn_ids & without
  end
  test "the family export writes the parts in the CSV and the whole split, linked, in the NDJSON" do
    children = @entry.split!([ { name: "Part A", amount: 70 }, { name: "Part B", amount: 30 } ])
    exporter = Family::DataExporter.new(@family)

    csv_names = CSV.parse(exporter.send(:generate_transactions_csv), headers: true).map { |row| row["name"] }
    assert_includes csv_names, "Part A"
    assert_not_includes csv_names, "Supermarket"

    lines = exporter.send(:generate_ndjson).lines.map { |line| JSON.parse(line) }.select { |line| line["type"] == "Transaction" }
    by_entry = lines.index_by { |line| line.dig("data", "entry_id") }
    assert by_entry.dig(@entry.id, "data", "excluded")
    assert_equal [ @entry.id ], children.map { |child| by_entry.dig(child.id, "data", "parent_entry_id") }.uniq
  end
end
