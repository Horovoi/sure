require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::GetTransactions.new(@user)
  end

  test "returns ids, the transaction name and notes" do
    @transaction.entry.update!(notes: "Visible note")

    row = find_row(@function.call("order" => "asc", "search" => @transaction.entry.name), @transaction)

    assert_not_nil row
    assert_equal @transaction.entry.id, row[:entry_id]
    assert_equal "Starbucks", row[:name]
    assert_equal "Visible note", row[:notes]
    assert_equal "standard", row[:kind]
    assert_equal "expense", row[:classification]
    assert_equal "outflow", row[:direction]
  end

  test "a tagged transaction lists its tag names" do
    row = find_row(@function.call("search" => @transaction.entry.name), @transaction)

    assert_equal [ "Emergency fund", "Trips" ], row[:tags].sort
  end

  test "rows are compact: unset and false keys are left out" do
    # The fixture transaction is tagged (taggings.yml), so clear its tags too
    @transaction.update!(merchant: nil, category: nil, tags: [])

    row = find_row(@function.call("search" => @transaction.entry.name), @transaction)

    %i[merchant category tags notes pending excluded is_transfer transfer_account].each do |key|
      assert_not row.key?(key), "#{key} should be absent"
    end
  end

  test "flags a pending transaction and stays silent on a settled one" do
    @transaction.update!(extra: { "manual" => { "pending" => true } })
    assert_equal true, find_row(@function.call("search" => @transaction.entry.name), @transaction)[:pending]

    @transaction.update!(extra: {})
    assert_not find_row(@function.call("search" => @transaction.entry.name), @transaction).key?(:pending)
  end

  test "a transfer between two own accounts appears once with classification transfer" do
    outflow = transactions(:transfer_out)
    inflow = transactions(:transfer_in)

    result = @function.call("search" => "Payment")
    ids = result[:transactions].map { |t| t[:id] }

    assert_includes ids, outflow.id
    assert_not_includes ids, inflow.id, "the inflow leg duplicates the outflow leg"
    assert_equal 1, result[:total_results]

    row = find_row(result, outflow)
    assert_equal "transfer", row[:classification]
    assert_equal true, row[:is_transfer]
    assert_equal "cc_payment", row[:kind]
    assert_equal accounts(:credit_card).name, row[:transfer_account]
  end

  test "the inflow leg is listed when the filters leave the outflow leg out" do
    inflow = transactions(:transfer_in)

    row = find_row(@function.call("accounts" => [ accounts(:credit_card).name ]), inflow)

    assert_not_nil row
    assert_equal "transfer", row[:classification]
    assert_equal "inflow", row[:direction]
    assert_equal accounts(:depository).name, row[:transfer_account]
  end

  test "types income and expense leave transfers out" do
    result = @function.call("types" => [ "income", "expense" ])

    assert result[:transactions].any?
    assert(result[:transactions].none? { |t| t[:classification] == "transfer" })
  end

  test "an investment contribution counts as an expense" do
    entry = accounts(:depository).entries.create!(name: "To brokerage", date: Date.current, amount: 300, currency: "USD",
      entryable: Transaction.new(kind: "investment_contribution"))

    row = find_row(@function.call("search" => "To brokerage"), entry.entryable)

    assert_equal "expense", row[:classification]
  end

  test "filters by type" do
    accounts(:depository).entries.create!(name: "Salary", date: Date.current, amount: -1000, currency: "USD", entryable: Transaction.new)

    result = @function.call("types" => [ "income" ])

    assert result[:transactions].any?
    assert(result[:transactions].all? { |t| t[:classification] == "income" })
  end

  test "schema does not inline user data enums" do
    schema = @function.params_schema

    %i[accounts categories merchants tags].each do |key|
      assert_equal({ type: "string" }, schema[:properties][key][:items], "#{key} should be a plain string array")
    end
  end

  test "honors page_size and clamps it" do
    result = @function.call("page_size" => 1)

    assert_equal 1, result[:page_size]
    assert_equal 1, result[:transactions].size
    assert result[:total_pages] > 1

    assert_equal Assistant::Function::MAX_PAGE_SIZE, @function.call("page_size" => 10_000)[:page_size]
  end

  test "an invalid page reads as the first page" do
    assert_equal 1, @function.call("page" => -3)[:page]
  end

  test "sorts by absolute amount" do
    amounts = @function.call("sort_by" => "amount", "order" => "desc")[:transactions].map { |t| t[:amount] }

    assert_equal amounts.sort.reverse, amounts
  end

  test "filters by account_ids and ignores ids that are not UUIDs" do
    account = @transaction.entry.account

    result = @function.call("account_ids" => [ account.id ])
    assert result[:transactions].any?
    assert(result[:transactions].all? { |t| t[:account] == account.name })

    assert_empty @function.call("account_ids" => [ "not-a-uuid" ])[:transactions]
  end

  test "transactions on hidden accounts are left out" do
    accounts(:depository).update!(status: "disabled")

    assert_nil find_row(@function.call("search" => @transaction.entry.name), @transaction)
  end

  test "the Uncategorized category filter finds transactions without a category" do
    entry = accounts(:depository).entries.create!(name: "AI uncategorized lookup", date: Date.current, amount: 42,
      currency: "USD", entryable: Transaction.new)

    ids = @function.call("categories" => [ "Uncategorized" ])[:transactions].map { |t| t[:id] }

    assert_includes ids, entry.entryable.id
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "a row from an account excluded from reports is listed with a flag" do
    @transaction.entry.account.update!(exclude_from_reports: true)

    row = find_row(@function.call("order" => "asc", "search" => @transaction.entry.name), @transaction)

    assert_not_nil row
    assert_equal true, row[:account_excluded_from_reports]
  end

  test "a row from an included account has no exclusion flag" do
    row = find_row(@function.call("order" => "asc", "search" => @transaction.entry.name), @transaction)

    assert_not row.key?(:account_excluded_from_reports)
  end

  private
    def find_row(result, transaction)
      result[:transactions].find { |item| item[:id] == transaction.id }
    end
end
