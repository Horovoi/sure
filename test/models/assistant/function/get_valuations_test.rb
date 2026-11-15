require "test_helper"

class Assistant::Function::GetValuationsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @fn = Assistant::Function::GetValuations.new(@user)

    @entry = @account.entries.create!(
      name: "Manual valuation",
      date: Date.current,
      amount: 12_345,
      currency: @account.currency,
      notes: "statement 2026-07",
      entryable: Valuation.new(kind: "reconciliation")
    )
  end

  test "has correct name and is not strict" do
    assert_equal "get_valuations", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "lists valuations newest first with kind and notes" do
    result = @fn.call
    row = result[:valuations].find { |v| v[:entry_id] == @entry.id }

    assert_equal @entry.id, result[:valuations].first[:entry_id]
    assert_equal "reconciliation", row[:kind]
    assert_equal "statement 2026-07", row[:notes]
    assert_equal @account.id, row[:account][:id]
    assert_equal 12_345.0, row[:amount]
  end

  test "filters by account_id and validates its format" do
    result = @fn.call("account_id" => @account.id)
    assert(result[:valuations].all? { |v| v[:account][:id] == @account.id })

    assert_equal "invalid_account_id", @fn.call("account_id" => "not-a-uuid")[:error]
  end

  test "filters by date range" do
    assert_includes @fn.call("start_date" => Date.current.to_s, "end_date" => Date.current.to_s)[:valuations].map { |v| v[:entry_id] }, @entry.id
    assert_not_includes @fn.call("end_date" => 1.year.ago.to_date.to_s)[:valuations].map { |v| v[:entry_id] }, @entry.id
  end

  test "malformed dates and reversed ranges fail loudly" do
    assert_equal "invalid_date", @fn.call("start_date" => "not-a-date")[:error]
    assert_equal "invalid_date", @fn.call("start_date" => Date.current.to_s, "end_date" => 1.year.ago.to_date.to_s)[:error]
  end

  test "an invalid page reads as the first page" do
    result = @fn.call("page" => 0)

    assert_equal 1, result[:page]
    assert_includes result[:valuations].map { |v| v[:entry_id] }, @entry.id
  end

  test "leaves out valuations on hidden accounts and other families" do
    @account.update!(status: "disabled")

    assert_not_includes @fn.call[:valuations].map { |v| v[:entry_id] }, @entry.id
    assert_empty Assistant::Function::GetValuations.new(users(:empty)).call[:valuations]
  end
end
