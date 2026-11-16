require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "bulk update" do
    transactions = @user.family.entries.transactions

    assert_difference [ "Entry.count", "Transaction.count" ], 0 do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transactions.map(&:id),
          date: 1.day.ago.to_date,
          category_id: Category.second.id,
          merchant_id: Merchant.second.id,
          tag_ids: [ Tag.first.id, Tag.second.id ],
          notes: "Updated note"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{transactions.count} transactions updated", flash[:notice]

    transactions.reload.each do |transaction|
      assert_equal 1.day.ago.to_date, transaction.date
      assert_equal Category.second, transaction.transaction.category
      assert_equal Merchant.second, transaction.transaction.merchant
      assert_equal "Updated note", transaction.notes
      assert_equal [ Tag.first.id, Tag.second.id ], transaction.entryable.tag_ids.sort
    end
  end

  test "bulk update preloads the transactions instead of loading each one" do
    account = accounts(:depository)
    entries = 4.times.map { |i| create_bulk_test_transaction(account, "Preload #{i}") }

    assert_no_queries_match(/SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" = /) do
      post transactions_bulk_update_url, params: {
        bulk_update: { entry_ids: entries.map(&:id), notes: "Updated in bulk" }
      }
    end

    assert_redirected_to transactions_url
    assert entries.all? { |entry| entry.reload.notes == "Updated in bulk" }
  end

  test "bulk update preserves tags when tag_ids are omitted" do
    entry = entries(:transaction)
    original_tag_ids = entry.entryable.tag_ids.sort

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        notes: "Only updating notes"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "Only updating notes", entry.reload.notes
    assert_equal original_tag_ids, entry.entryable.reload.tag_ids.sort
  end

  test "bulk date change syncs each account once from the earliest date" do
    entry = entries(:transaction)
    old_date = entry.date
    new_date = old_date - 10.days

    Account.any_instance.expects(:sync_later).with(window_start_date: new_date).once

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], date: new_date } }

    assert_equal new_date, entry.reload.date
  end

  test "bulk update without a date change does not sync" do
    entry = entries(:transaction)
    Account.any_instance.expects(:sync_later).never

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], notes: "Only notes" } }
  end

  test "a selection with balance updates gets only the entry fields" do
    account = accounts(:depository)
    valuation = account.entries.create!(date: 8.days.ago.to_date, name: "Value", amount: 100, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))
    transaction = entries(:transaction)

    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ valuation.id, transaction.id ], category_id: Category.second.id, notes: "Mixed note" }
    }

    assert_redirected_to transactions_url
    assert_equal "Mixed note", valuation.reload.notes
    assert_equal Category.second, transaction.reload.transaction.category
  end

  test "an update that breaks an entry rolls the whole selection back" do
    account = accounts(:depository)
    first = account.entries.create!(date: 8.days.ago.to_date, name: "Value 1", amount: 100, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))
    second = account.entries.create!(date: 9.days.ago.to_date, name: "Value 2", amount: 200, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))

    # Two balance updates of one account cannot share a date
    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ first.id, second.id ], date: 10.days.ago.to_date, notes: "Rolled back" }
    }

    assert_redirected_to transactions_url
    assert flash[:alert].present?
    assert_nil first.reload.notes
    assert_equal 8.days.ago.to_date, first.date
    assert_equal 9.days.ago.to_date, second.reload.date
  end

  test "a category-only bulk edit skips the sync and asks for recurring detection once" do
    account = accounts(:depository)
    entries = 3.times.map { |i| create_bulk_test_transaction(account, "Category #{i}") }

    assert_no_enqueued_jobs only: SyncJob do
      assert_enqueued_jobs 1, only: IdentifyRecurringTransactionsJob do
        post transactions_bulk_update_url, params: {
          bulk_update: { entry_ids: entries.map(&:id), category_id: categories(:subscriptions).id }
        }
      end
    end

    assert entries.all? { |entry| entry.reload.transaction.category == categories(:subscriptions) }
  end

  test "a notes-only bulk edit asks for no recurring detection" do
    entry = entries(:transaction)

    assert_no_enqueued_jobs only: [ SyncJob, IdentifyRecurringTransactionsJob ] do
      post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], notes: "Bulk note" } }
    end
  end

  test "bulk rename sets the name on every selected entry and locks it as a user edit" do
    account = accounts(:depository)
    entries = 2.times.map { |i| create_bulk_test_transaction(account, "Old name #{i}") }

    assert_no_enqueued_jobs only: SyncJob do
      post transactions_bulk_update_url, params: { bulk_update: { entry_ids: entries.map(&:id), name: "  Coffee shop  " } }
    end

    assert_redirected_to transactions_url
    entries.each do |entry|
      entry.reload
      assert_equal "Coffee shop", entry.name
      assert entry.locked?(:name), "the new name is locked against rules and imports"
      assert entry.user_locked?(:name)
    end
  end

  test "a blank name in bulk edit keeps each name" do
    account = accounts(:depository)
    entries = 2.times.map { |i| create_bulk_test_transaction(account, "Keep #{i}") }

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: entries.map(&:id), name: "   ", notes: "Note" } }

    assert_equal [ "Keep 0", "Keep 1" ], entries.map { |entry| entry.reload.name }.sort
    entries.each { |entry| assert_not entry.locked?(:name) }
  end

  # --- w3-toolstrx reconciliation-status ---
  test "bulk reconcile marks the selected manual transactions and counts only those" do
    account = accounts(:depository)
    entries = 2.times.map { |i| create_bulk_test_transaction(account, "Reconcile #{i}") }
    synced = create_bulk_test_transaction(accounts(:connected), "Synced")

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: (entries + [ synced ]).map(&:id), reconciled_status: "cleared" } }

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_updates.create.success", count: 2), flash[:notice]
    assert entries.all? { |entry| entry.reload.cleared? }
    assert synced.reload.unreconciled?
    entries.each { |entry| assert_not entry.user_modified? }
  end

  test "an unknown reconciliation status is refused and nothing changes" do
    entry = create_bulk_test_transaction(accounts(:depository), "Refused")

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], reconciled_status: "approved", notes: "x" } }

    assert_equal I18n.t("transactions.reconcile.failure"), flash[:alert]
    assert entry.reload.unreconciled?
    assert_nil entry.notes
  end

  test "bulk reconcile cannot reach another family's entries" do
    entry = create_bulk_test_transaction(accounts(:depository), "Ours")
    sign_in users(:empty)

    post transactions_bulk_update_url, params: { bulk_update: { entry_ids: [ entry.id ], reconciled_status: "reconciled" } }

    assert entry.reload.unreconciled?
  end

  private
    def create_bulk_test_transaction(account, name)
      account.entries.create!(
        date: 3.days.ago.to_date, name: name, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    test "the tag picker is as tall as its tags, and says so when there are none" do
      family = users(:family_admin).family
      get new_transactions_bulk_update_url
      assert_select "select[name='bulk_update[tag_ids][]'][size=?]", (family.tags.count + 1).clamp(2, 6).to_s

      family.tags.destroy_all
      get new_transactions_bulk_update_url
      assert_select "select[name='bulk_update[tag_ids][]']", count: 0
      assert_match I18n.t("transactions.bulk_updates.new.no_tags"), response.body
    end
end
