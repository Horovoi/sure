require "test_helper"

class Assistant::Function::CreateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @fn = Assistant::Function::CreateTransaction.new(@user)
  end

  test "is a write tool that is not idempotent and names Transaction" do
    assert_equal :write, @fn.scope_tag
    assert_not @fn.idempotent?
    assert_equal "Transaction", @fn.record_type
  end

  test "creates a transaction like the form does and queues the account sync" do
    category = categories(:food_and_drink)
    tag = tags(:one)

    Entry.any_instance.expects(:sync_account_later).once

    result = nil
    assert_difference -> { @account.entries.count }, 1 do
      result = @fn.call(
        "account_id" => @account.id, "date" => Date.current.iso8601, "amount" => 250, "nature" => "expense",
        "name" => "  Silpo  ", "category_id" => category.id, "tag_ids" => [ tag.id ], "notes" => "weekly shop"
      )
    end

    assert result[:created]
    entry = Entry.find(result[:entry_id])
    assert_equal result[:id], entry.transaction.id
    assert_equal "Silpo", entry.name
    assert_equal 250, entry.amount
    assert_equal @account.currency, entry.currency
    assert_equal category, entry.transaction.category
    assert_equal [ tag ], entry.transaction.tags.to_a
    assert_equal "standard", entry.transaction.kind
    assert_equal "mcp", entry.source
    assert_not entry.linked?
    assert entry.locked?(:name)
  end

  test "income makes the amount negative" do
    result = @fn.call("account_id" => @account.id, "date" => Date.current.iso8601, "amount" => 1000, "nature" => "income", "name" => "Salary")

    assert_equal(-1000, Entry.find(result[:entry_id]).amount)
  end

  test "a repeat with the same external_id returns the first transaction" do
    params = { "account_id" => @account.id, "date" => Date.current.iso8601, "amount" => 99, "name" => "Statement row 7", "external_id" => "stmt-2026-11-row-7" }

    first = nil
    second = nil
    assert_difference -> { Entry.count }, 1 do
      first = @fn.call(params)
      second = @fn.call(params.merge("amount" => 12345))
    end

    assert first[:created]
    assert_equal false, second[:created]
    assert_equal first[:id], second[:id]
    assert_equal 99, Entry.find(second[:entry_id]).amount
    assert_not Entry.find(first[:entry_id]).linked?
  end

  test "an external_id is scoped to its account" do
    params = { "date" => Date.current.iso8601, "amount" => 5, "name" => "Coffee", "external_id" => "row-1" }

    assert_difference -> { Entry.count }, 2 do
      @fn.call(params.merge("account_id" => @account.id))
      @fn.call(params.merge("account_id" => accounts(:credit_card).id))
    end
  end

  test "refuses ids of another family and malformed ids" do
    other_family_account = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)

    assert_equal "account_not_found", @fn.call(base_params.merge("account_id" => other_family_account.id))[:error]
    assert_equal "account_not_found", @fn.call(base_params.merge("account_id" => "nope"))[:error]
    assert_equal "invalid_category", @fn.call(base_params.merge("category_id" => categories(:one).id))[:error]
    assert_equal "invalid_tags", @fn.call(base_params.merge("tag_ids" => [ tags(:three).id ]))[:error]
    assert_equal "invalid_merchant", @fn.call(base_params.merge("merchant_id" => SecureRandom.uuid))[:error]
  end

  test "refuses future dates, bad amounts, blank names, unknown currencies and transfer kinds" do
    assert_equal "invalid_date", @fn.call(base_params.merge("date" => (Date.current + 1).iso8601))[:error]
    assert_equal "invalid_date", @fn.call(base_params.merge("date" => "15.11.2026"))[:error]
    assert_equal "invalid_amount", @fn.call(base_params.merge("amount" => "NaN"))[:error]
    assert_equal "invalid_amount", @fn.call(base_params.merge("amount" => true))[:error]
    assert_equal "invalid_name", @fn.call(base_params.merge("name" => "   "))[:error]
    assert_equal "invalid_currency", @fn.call(base_params.merge("currency" => "XYZ"))[:error]
    assert_equal "invalid_kind", @fn.call(base_params.merge("kind" => "funds_movement"))[:error]
  end

  test "one_time is a kind the tool may set" do
    result = @fn.call(base_params.merge("kind" => "one_time"))

    assert_equal "one_time", Entry.find(result[:entry_id]).transaction.kind
  end

  test "a failed sync enqueue is a warning, not a failed create" do
    Entry.any_instance.stubs(:sync_account_later).raises(RuntimeError, "queue down")

    result = @fn.call(base_params)

    assert result[:created]
    assert result[:warning].present?
    assert Entry.exists?(result[:entry_id])
  end

  private
    def base_params
      { "account_id" => @account.id, "date" => Date.current.iso8601, "amount" => 10, "name" => "Test" }
    end
end
