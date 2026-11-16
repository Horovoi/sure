require "test_helper"

class Transactions::BulkDeletionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "bulk delete" do
    transactions = @user.family.entries.transactions
    delete_count = transactions.size

    assert_difference([ "Transaction.count", "Entry.count" ], -delete_count) do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: {
          entry_ids: transactions.pluck(:id)
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{delete_count} transactions deleted", flash[:notice]
  end

  test "a part of a split is kept and the notice says why" do
    parent = create_transaction(account: accounts(:depository), name: "Kyivstar", amount: 400)
    parent.split!([ { name: "Kyivstar", amount: 350 }, { name: "Roaming fee", amount: 50 } ])
    part = parent.child_entries.find_by!(name: "Roaming fee")

    assert_no_difference "Entry.count" do
      post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ part.id ] } }
    end

    assert_equal "0 transactions deleted. 1 kept: #{I18n.t("activerecord.errors.models.entry.attributes.base.split_child_not_deletable")}", flash[:notice]
  end

  test "deleting a split with its parts selected too reports only what was asked" do
    parent = create_transaction(account: accounts(:depository), name: "Shop", amount: 100)
    parent.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    ids = [ parent.id, *parent.child_entries.pluck(:id) ]

    assert_difference "Entry.count", -3 do
      post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: ids } }
    end

    assert_no_match(/kept/, flash[:notice])
  end
end
