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
end
