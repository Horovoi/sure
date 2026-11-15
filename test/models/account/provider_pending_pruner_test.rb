require "test_helper"

class Account::ProviderPendingPrunerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @pruner = Account::ProviderPendingPruner.new(@account, source: "monobank")
  end

  test "destroys stale holds and keeps the ones still reported" do
    stale = hold("hold-1")
    kept = hold("hold-2")
    settled = @account.entries.create!(date: Date.current, amount: 5, currency: "USD", name: "Settled", external_id: "tx-9", source: "monobank",
      entryable: Transaction.new(extra: { "monobank" => { "pending" => false } }))

    result = @pruner.prune!(keep_external_ids: [ "hold-2" ])

    assert_equal({ pruned: 1, detached: 0 }, result)
    assert_not Entry.exists?(stale.id)
    assert Entry.exists?(kept.id)
    assert Entry.exists?(settled.id)
  end

  test "leaves other providers' holds alone" do
    other = @account.entries.create!(date: Date.current, amount: 5, currency: "USD", name: "Other", external_id: "x", source: "lunchflow",
      entryable: Transaction.new(extra: { "lunchflow" => { "pending" => true } }))

    @pruner.prune!(keep_external_ids: [])

    assert Entry.exists?(other.id)
  end

  test "a category, name or exclusion alone does not keep a released hold" do
    edits = {
      user_modified: ->(entry) { entry.update!(user_modified: true, name: "Renamed") },
      category_locked: ->(entry) { entry.transaction.update!(category: categories(:food_and_drink)); entry.transaction.lock_attr!(:category_id) },
      excluded: ->(entry) { entry.update!(excluded: true) }
    }

    edits.each do |name, edit|
      entry = hold("hold-#{name}")
      edit.call(entry)

      assert_not @pruner.protected?(entry.reload), name
      assert_equal({ pruned: 1, detached: 0 }, @pruner.prune!(keep_external_ids: []), name)
      assert_not Entry.exists?(entry.id), name
    end
  end

  test "a released hold the user attached something to stays pending and counts in no balance" do
    entry = hold("hold-kept")
    entry.update!(notes: "Dinner with Ann")

    @pruner.prune!(keep_external_ids: [])

    entry.reload
    assert entry.transaction.pending?
    assert_not_includes @account.entries.excluding_pending, entry
    assert_not_includes @account.entries.excluding_released_holds, entry
    assert_equal({ pruned: 0, detached: 0 }, @pruner.prune!(keep_external_ids: []), "released once")
  end

  test "releases each protected hold instead of destroying it" do
    protections = {
      notes: ->(entry) { entry.update!(notes: "Dinner with Ann") },
      import: ->(entry) { entry.update_columns(import_id: imports(:transaction).id) },
      tags: ->(entry) { entry.transaction.taggings.create!(tag: tags(:one)) },
      goal: ->(entry) { entry.transaction.update!(extra: entry.transaction.extra.merge("goal" => { "id" => "g" })) },
      provider_claim: ->(entry) { entry.transaction.update!(extra: entry.transaction.extra.merge("provider_claim" => { "source" => "monobank" })) },
      subscription: ->(entry) { entry.transaction.update_columns(recurring_transaction_id: recurring_transactions(:netflix_subscription).id) },
      attachment: ->(entry) { entry.transaction.attachments.attach(io: StringIO.new("%PDF-1.4"), filename: "r.pdf", content_type: "application/pdf") },
      transfer: ->(entry) { transfer_with(entry) }
    }

    protections.each do |name, protect|
      entry = hold("hold-#{name}")
      protect.call(entry)

      assert @pruner.protected?(entry.reload), "#{name} should protect the hold"
      result = @pruner.prune!(keep_external_ids: [])

      assert_equal({ pruned: 0, detached: 1 }, result, name)
      entry.reload
      assert entry.transaction.pending?, name
      assert entry.transaction.extra.dig("monobank", "hold_released_at").present?, name
    end
  end

  test "a detached hold keeps its transfer" do
    entry = hold("hold-t")
    transfer = transfer_with(entry)

    assert_no_difference -> { Transfer.count } do
      @pruner.prune!(keep_external_ids: [])
    end

    assert Transfer.exists?(transfer.id)
  end

  test "logs the detached count" do
    hold("hold-n").update!(notes: "kept")

    assert_difference -> { DebugLogEntry.where(source: "Account::ProviderPendingPruner").count }, 1 do
      @pruner.prune!(keep_external_ids: [])
    end
  end

  private
    def hold(external_id)
      @account.entries.create!(date: Date.current, amount: 12, currency: "USD", name: "Hold", external_id: external_id, source: "monobank",
        entryable: Transaction.new(extra: { "monobank" => { "pending" => true, "id" => external_id } }))
    end

    def transfer_with(entry)
      other = accounts(:credit_card).entries.create!(date: Date.current, amount: -12, currency: "USD", name: "In", entryable: Transaction.new)
      Transfer.create!(outflow_transaction: entry.transaction, inflow_transaction: other.transaction, status: "pending")
    end
end
