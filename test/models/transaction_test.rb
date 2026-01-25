require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  test "pending? is true when extra.plaid.pending is truthy" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => "true" } })

    assert transaction.pending?
  end

  test "pending? is false when no provider pending metadata is present" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "investment_contribution is a valid kind" do
    transaction = Transaction.new(kind: "investment_contribution")

    assert_equal "investment_contribution", transaction.kind
    assert transaction.investment_contribution?
  end

  test "all transaction kinds are valid" do
    valid_kinds = %w[standard funds_movement cc_payment loan_payment one_time investment_contribution]

    valid_kinds.each do |kind|
      transaction = Transaction.new(kind: kind)
      assert_equal kind, transaction.kind, "#{kind} should be a valid transaction kind"
    end
  end

  test "ACTIVITY_LABELS contains all valid labels" do
    assert_includes Transaction::ACTIVITY_LABELS, "Buy"
    assert_includes Transaction::ACTIVITY_LABELS, "Sell"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep In"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep Out"
    assert_includes Transaction::ACTIVITY_LABELS, "Dividend"
    assert_includes Transaction::ACTIVITY_LABELS, "Reinvestment"
    assert_includes Transaction::ACTIVITY_LABELS, "Interest"
    assert_includes Transaction::ACTIVITY_LABELS, "Fee"
    assert_includes Transaction::ACTIVITY_LABELS, "Transfer"
    assert_includes Transaction::ACTIVITY_LABELS, "Contribution"
    assert_includes Transaction::ACTIVITY_LABELS, "Withdrawal"
    assert_includes Transaction::ACTIVITY_LABELS, "Exchange"
    assert_includes Transaction::ACTIVITY_LABELS, "Other"
  end

  # Pending scope tests
  test "pending scope returns transactions with pending flag from any provider" do
    pending_plaid = Transaction.create!(extra: { "plaid" => { "pending" => true } })
    pending_lunchflow = Transaction.create!(extra: { "lunchflow" => { "pending" => true } })
    confirmed = Transaction.create!(extra: { "plaid" => { "pending" => false } })

    results = Transaction.pending

    assert_includes results, pending_plaid
    assert_includes results, pending_lunchflow
    assert_not_includes results, confirmed
  end

  test "excluding_pending scope excludes pending transactions" do
    pending_tx = Transaction.create!(extra: { "plaid" => { "pending" => true } })
    confirmed_tx = Transaction.create!(extra: { "plaid" => { "pending" => false } })
    empty_extra_tx = Transaction.create!(extra: {})

    results = Transaction.excluding_pending

    assert_not_includes results, pending_tx
    assert_includes results, confirmed_tx
    assert_includes results, empty_extra_tx
  end

  test "pending scope works with lunchflow provider" do
    lunchflow_pending = Transaction.create!(extra: { "lunchflow" => { "pending" => true } })
    lunchflow_confirmed = Transaction.create!(extra: { "lunchflow" => { "pending" => false } })

    results = Transaction.pending

    assert_includes results, lunchflow_pending
    assert_not_includes results, lunchflow_confirmed
  end

  test "pending? handles nil extra gracefully" do
    transaction = Transaction.new(extra: nil)

    assert_not transaction.pending?
  end

  test "pending? handles empty extra gracefully" do
    transaction = Transaction.new(extra: {})

    assert_not transaction.pending?
  end

  test "pending? handles malformed provider data" do
    transaction = Transaction.new(extra: { "plaid" => "not_a_hash" })

    assert_not transaction.pending?
  end
end
