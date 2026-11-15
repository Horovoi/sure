require "test_helper"

# How a provider's rows meet the history an account already has: claims (±3 days),
# the cutover date, MCC-style categories, and the balance it writes.
class Account::ProviderImportAdapterClaimTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    travel_to Date.new(2026, 11, 15)
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Mono Visa", balance: 0, currency: "UAH", accountable: CreditCard.new)
    @adapter = Account::ProviderImportAdapter.new(@account)
    @groceries = @family.categories.create!(name: "Groceries", classification: "expense")
    @other = @family.categories.create!(name: "Other", classification: "expense")
  end

  test "a claim keeps date, amount, name, category, merchant, notes and tags" do
    merchant = @family.merchants.create!(name: "Silpo")
    tag = @family.tags.create!(name: "Food")
    manual = manual_entry(date: 2.days.ago, amount: 450, name: "Silpo by hand", notes: "weekly shop")
    manual.transaction.update!(category: @other, merchant: merchant)
    manual.transaction.taggings.create!(tag: tag)

    assert_no_difference -> { @account.entries.count } do
      entry = import("tx-1", Date.current, 450, name: "Сільпо", extra: { "monobank" => { "mcc" => 5411 } }, category_id_if_blank: @groceries.id)

      assert_equal manual.id, entry.id
    end

    manual.reload
    assert_equal [ "tx-1", "monobank" ], [ manual.external_id, manual.source ]
    assert_equal [ 2.days.ago.to_date, 450 ], [ manual.date, manual.amount ]
    assert_equal [ "Silpo by hand", "weekly shop" ], [ manual.name, manual.notes ]
    assert_equal @other, manual.transaction.category
    assert_equal merchant, manual.transaction.merchant
    assert_equal [ tag ], manual.transaction.tags.to_a
    assert_equal 5411, manual.transaction.extra.dig("monobank", "mcc")
    assert_equal "monobank", manual.transaction.extra.dig("provider_claim", "source")
    assert_equal [ { id: manual.id, external_id: "tx-1", date: manual.date } ], @adapter.claimed_entries
  end

  test "a claimed entry is left alone by later syncs" do
    manual = manual_entry(date: 1.day.ago, amount: 100)
    import("tx-2", Date.current, 100)

    @adapter.reset_skipped_entries!
    entry = import("tx-2", Date.current, 999, name: "Changed")

    assert_equal manual.id, entry.id
    assert_equal [ 1.day.ago.to_date, 100, "Manual" ], [ manual.reload.date, manual.amount, manual.name ]
    assert_equal [ "provider_claimed" ], @adapter.skipped_entries.map { |skip| skip[:reason] }
  end

  test "a claimed blank-category entry gets category_id_if_blank, a protected one does not" do
    blank = manual_entry(date: Date.current, amount: 10)
    locked = manual_entry(date: Date.current, amount: 11)
    locked.update!(import_locked: true)

    import("tx-a", Date.current, 10, category_id_if_blank: @groceries.id)
    import("tx-b", Date.current, 11, category_id_if_blank: @groceries.id)

    assert_equal @groceries, blank.reload.transaction.category
    assert_nil locked.reload.transaction.category
    assert_equal "tx-b", locked.external_id
  end

  test "pending rows never claim" do
    manual = manual_entry(date: Date.current, amount: 75)

    entry = import("hold-1", Date.current, 75, extra: { "monobank" => { "pending" => true } })

    assert_not_equal manual.id, entry.id
    assert entry.transaction.pending?
    assert_nil manual.reload.external_id
  end

  test "claimed_entry nil never claims and an explicit entry is taken" do
    manual = manual_entry(date: Date.current, amount: 60)
    other = manual_entry(date: 1.day.ago, amount: 60)

    created = import("tx-n", Date.current, 60, claimed_entry: nil)
    assert_not_includes [ manual.id, other.id ], created.id

    claimed = import("tx-e", Date.current, 60, claimed_entry: other)
    assert_equal other.id, claimed.id
    assert_equal 1.day.ago.to_date, other.reload.date
  end

  test "an explicit entry from another account or already owned is not taken" do
    foreign = accounts(:depository).entries.create!(date: Date.current, amount: 61, currency: "USD", name: "x", entryable: Transaction.new)
    owned = manual_entry(date: Date.current, amount: 61)
    owned.update!(external_id: "tx-owned", source: "monobank")

    entry = import("tx-f", Date.current, 61, claimed_entry: foreign)
    assert_not_equal foreign.id, entry.id
    entry = import("tx-g", Date.current, 61, claimed_entry: owned)
    assert_not_equal owned.id, entry.id
  end

  test "rows before the cutover are skipped unless they claim" do
    manual = manual_entry(date: 10.days.ago, amount: 30)
    cutover = 5.days.ago.to_date

    assert_no_difference -> { @account.entries.count } do
      assert_nil import("old", 9.days.ago, 31, cutover_date: cutover)
      assert_nil import("old-hold", 9.days.ago, 32, cutover_date: cutover, extra: { "monobank" => { "pending" => true } })
      assert_equal manual.id, import("overlap", 9.days.ago, 30, cutover_date: cutover).id
    end

    assert_equal %w[before_cutover before_cutover], @adapter.skipped_entries.map { |skip| skip[:reason] }
    assert_equal [ "old", 9.days.ago.to_date ], @adapter.skipped_entries.first.values_at(:external_id, :date)

    assert_difference -> { @account.entries.count }, 1 do
      import("new", cutover, 33, cutover_date: cutover)
    end
  end

  test "category_id_if_blank fills only a blank category, category_id keeps its meaning" do
    entry = import("tx-c", Date.current, 20, category_id_if_blank: @groceries.id)
    assert_equal @groceries, entry.transaction.reload.category

    entry.transaction.update!(category: @other)
    import("tx-c", Date.current, 20, category_id_if_blank: @groceries.id)
    assert_equal @other, entry.transaction.reload.category

    with_both = import("tx-d", Date.current, 21, category_id: @other.id, category_id_if_blank: @groceries.id)
    assert_equal @other, with_both.transaction.reload.category
  end

  test "generated subscription charges are left to the reconciler" do
    generated = manual_entry(date: Date.current, amount: 199, source: "subscription")

    entry = import("tx-s", 1.day.ago, 199)

    assert_not_equal generated.id, entry.id
    assert_nil generated.reload.external_id
  end

  test "the activity kind is not written on a transfer leg" do
    investment = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment)
    entry = adapter.import_transaction(external_id: "inv-1", amount: 100, currency: "USD", date: Date.current, name: "Cash", source: "lunchflow", claimed_entry: nil)
    inflow = accounts(:depository).entries.create!(date: Date.current, amount: -100, currency: "USD", name: "In", entryable: Transaction.new)
    Transfer.create!(outflow_transaction: entry.transaction, inflow_transaction: inflow.transaction, status: "pending")
    entry.transaction.update!(kind: "standard")

    adapter.import_transaction(external_id: "inv-1", amount: 100, currency: "USD", date: Date.current, name: "Cash", source: "lunchflow",
      investment_activity_label: "Transfer")

    assert_equal "standard", entry.transaction.reload.kind

    plain = adapter.import_transaction(external_id: "inv-2", amount: 50, currency: "USD", date: Date.current, name: "Sweep", source: "lunchflow",
      investment_activity_label: "Transfer", claimed_entry: nil)
    assert_equal "funds_movement", plain.transaction.reload.kind
  end

  test "update_balance writes the current anchor without a sync" do
    item = LunchflowItem.create!(family: @family, name: "Bank", api_key: "key")
    Account::ProviderLink.link!(account: @account, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "UAH", account_id: "c"))
    adapter = Account::ProviderImportAdapter.new(@account.reload)

    assert_no_enqueued_jobs only: SyncJob do
      assert adapter.update_balance(balance: 1234.5, cash_balance: 1000, source: "monobank").success?
      assert adapter.update_balance(balance: 1300, source: "monobank").success?
    end

    @account.reload
    anchors = @account.valuations.current_anchor.map(&:entry)
    assert_equal [ [ Date.current, 1300 ] ], anchors.map { |anchor| [ anchor.date, anchor.amount ] }
    assert_equal 1300, @account.balance
    assert_equal 1300, @account.cash_balance
  end

  test "update_balance turns a reconciliation dated today into the current anchor" do
    item = LunchflowItem.create!(family: @family, name: "Bank", api_key: "key")
    @account.entries.create!(date: 3.days.ago, amount: 900, currency: "UAH", name: "Old anchor", entryable: Valuation.new(kind: "current_anchor"))
    reconciliation = @account.entries.create!(date: Date.current, amount: 1000, currency: "UAH", name: "Counted", entryable: Valuation.new(kind: "reconciliation"))
    Account::ProviderLink.link!(account: @account, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "UAH", account_id: "c"))

    result = Account::ProviderImportAdapter.new(@account.reload).update_balance(balance: 1100, source: "monobank")

    assert result.success?, result.error
    anchors = @account.reload.valuations.current_anchor.map(&:entry)
    assert_equal [ [ reconciliation.id, Date.current, 1100 ] ], anchors.map { |anchor| [ anchor.id, anchor.date, anchor.amount ] }
    assert_equal [ [ 3.days.ago.to_date, 900 ] ], @account.valuations.reconciliation.map { |valuation| [ valuation.entry.date, valuation.entry.amount ] }
    assert_equal 1100, @account.balance
  end

  private
    def import(external_id, date, amount, **options)
      @adapter.import_transaction(external_id: external_id, amount: amount, currency: "UAH", date: date.to_date,
        name: options.delete(:name) || external_id, source: "monobank", **options)
    end

    def manual_entry(date:, amount:, name: "Manual", notes: nil, source: nil)
      @account.entries.create!(date: date.to_date, amount: amount, currency: "UAH", name: name, notes: notes, source: source, entryable: Transaction.new)
    end
end
