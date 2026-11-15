require "test_helper"

class Assistant::Function::UpdateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @entry = @transaction.entry
    @fn = Assistant::Function::UpdateTransaction.new(@user)
  end

  test "is an idempotent write tool" do
    assert_equal :write, @fn.scope_tag
    assert @fn.idempotent?
    assert_equal true, @fn.mcp_annotations[:idempotent_hint]
    assert_equal false, @fn.mcp_annotations[:destructive_hint]
  end

  test "changes only the fields passed, locks them and marks the entry user-modified" do
    category = categories(:subcategory)
    Account.any_instance.expects(:sync_later).with(window_start_date: @entry.date).once

    result = @fn.call("id" => @transaction.id, "category_id" => category.id, "notes" => "Updated by the assistant")

    assert result[:updated]
    assert_equal @transaction.id, result[:id]
    @entry.reload
    assert_equal category, @entry.transaction.category
    assert_equal "Updated by the assistant", @entry.notes
    assert_equal "Starbucks", @entry.name
    assert @entry.user_modified?
    assert @entry.transaction.locked?(:category_id)
  end

  test "a date moved later syncs from the old date" do
    old_date = 20.days.ago.to_date
    @entry.update!(date: old_date)
    Account.any_instance.expects(:sync_later).with(window_start_date: old_date).once

    @fn.call("id" => @transaction.id, "date" => 2.days.ago.to_date.iso8601)
  end

  test "date, amount and nature change the entry" do
    result = @fn.call("id" => @transaction.id, "date" => 10.days.ago.to_date.iso8601, "amount" => 42, "nature" => "income")

    assert result[:updated]
    @entry.reload
    assert_equal 10.days.ago.to_date, @entry.date
    assert_equal(-42, @entry.amount)
  end

  test "tag_ids replaces the list and [] clears it" do
    @fn.call("id" => @transaction.id, "tag_ids" => [ tags(:one).id, tags(:two).id ])
    assert_equal [ tags(:one), tags(:two) ].sort_by(&:id), @transaction.reload.tags.sort_by(&:id)

    @fn.call("id" => @transaction.id, "tag_ids" => [])
    assert_empty @transaction.reload.tags
  end

  test "null clears category, merchant and notes" do
    @fn.call("id" => @transaction.id, "category_id" => nil, "merchant_id" => nil, "notes" => nil)

    @transaction.reload
    assert_nil @transaction.category_id
    assert_nil @transaction.merchant_id
    assert_nil @transaction.entry.notes
  end

  test "audit_before is the transaction as it was" do
    before = @fn.audit_before("id" => @transaction.id)

    assert_equal @transaction.id, before[:id]
    assert_equal categories(:food_and_drink).id, before[:category_id]
    assert_equal "Starbucks", before[:name]
    assert_nil @fn.audit_before("id" => SecureRandom.uuid)
  end

  test "a transfer leg keeps its date, amount and kind" do
    leg = transactions(:transfer_out)

    assert_equal "transfer_locked", @fn.call("id" => leg.id, "amount" => 5)[:error]
    assert_equal "transfer_locked", @fn.call("id" => leg.id, "kind" => "one_time")[:error]
    assert_equal "cc_payment", leg.reload.kind

    # A transfer leg's category and notes are still editable
    assert @fn.call("id" => leg.id, "notes" => "card payoff")[:updated]
  end

  test "refuses unknown ids, ids of another family and empty calls" do
    assert_equal "not_found", @fn.call("id" => SecureRandom.uuid)[:error]
    assert_equal "not_found", @fn.call("id" => "not-a-uuid")[:error]
    assert_equal "invalid_category", @fn.call("id" => @transaction.id, "category_id" => categories(:one).id)[:error]
    assert_equal "invalid_tags", @fn.call("id" => @transaction.id, "tag_ids" => [ tags(:three).id ])[:error]
    assert_equal "invalid_kind", @fn.call("id" => @transaction.id, "kind" => "loan_payment")[:error]
    assert_equal "invalid_date", @fn.call("id" => @transaction.id, "date" => (Date.current + 1).iso8601)[:error]
    assert_equal "no_changes", @fn.call("id" => @transaction.id)[:error]
  end
end
