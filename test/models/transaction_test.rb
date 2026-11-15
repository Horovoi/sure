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

  # --- DS pickers (w1-ds) ---

  test "record_category_usage! touches the category only after a category change" do
    transaction = transactions(:one)
    category = categories(:subscriptions)

    transaction.update!(category: category)
    transaction.record_category_usage!
    assert_not_nil category.reload.last_used_at

    first_use = category.last_used_at
    transaction.update!(merchant: merchants(:netflix))
    transaction.record_category_usage!
    assert_equal first_use, category.reload.last_used_at
  end

  test "record_category_usage! does nothing when the category was cleared" do
    transaction = transactions(:one)

    transaction.update!(category: nil)

    assert_nothing_raised { transaction.record_category_usage! }
  end

  test "toggle_tag! adds a missing tag and removes a present one" do
    transaction = transactions(:one)
    tag = tags(:one)
    transaction.update!(tag_ids: [])

    transaction.toggle_tag!(tag)
    assert_equal [ tag.id ], transaction.tag_ids

    transaction.toggle_tag!(tag)
    assert_empty transaction.reload.tag_ids
  end

  # w2-transfers custom-exchange-rate
  test "exchange_rate is stored in extra as a decimal and read back" do
    transaction = Transaction.new
    transaction.exchange_rate = "41,25"

    assert_equal "41.25", transaction.extra["exchange_rate"]
    assert_equal BigDecimal("41.25"), transaction.exchange_rate
    assert transaction.valid?
  end

  test "a blank exchange_rate removes the rate and keeps the rest of extra" do
    transaction = Transaction.new(extra: { "exchange_rate" => "41.25", "plaid" => { "pending" => false } })
    transaction.exchange_rate = ""

    assert_nil transaction.exchange_rate
    assert_not transaction.extra.key?("exchange_rate")
    assert_equal({ "pending" => false }, transaction.extra["plaid"])
  end

  test "exchange_rate must be greater than zero" do
    [ "0", "-2" ].each do |value|
      transaction = Transaction.new(exchange_rate: value)
      assert_not transaction.valid?, "#{value} should be rejected"
      assert transaction.errors.of_kind?(:exchange_rate, :greater_than)
    end
  end

  test "exchange_rate must be a number and the bad value is never stored" do
    transaction = Transaction.new(extra: { "exchange_rate" => "40" })
    transaction.exchange_rate = "abc"

    assert_not transaction.valid?
    assert transaction.errors.of_kind?(:exchange_rate, :not_a_number)
    assert_not transaction.extra.key?("exchange_rate")
  end

  test "custom_exchange_rate_applies? only when the entry and account currencies differ" do
    account = accounts(:depository)
    foreign = Entry.new(account: account, currency: "EUR", amount: 10, date: Date.current, name: "x", entryable: Transaction.new(exchange_rate: "1.1"))
    local = Entry.new(account: account, currency: account.currency, amount: 10, date: Date.current, name: "x", entryable: Transaction.new(exchange_rate: "1.1"))

    assert foreign.transaction.custom_exchange_rate_applies?
    assert_not local.transaction.custom_exchange_rate_applies?
  end

  # --- Category ownership (w2-transfers transfer-form-fixes) ---

  test "a confirmed investment contribution's category belongs to its outflow leg" do
    outflow, inflow = transfer_legs(from: accounts(:depository), to: accounts(:investment), status: "confirmed")

    assert outflow.reload.investment_contribution?
    assert outflow.category_editable?
    assert_not outflow.category_set_on_transfer_outflow?
    assert_not inflow.reload.category_editable?
    assert inflow.category_set_on_transfer_outflow?
  end

  test "a confirmed loan payment's category belongs to its outflow leg" do
    outflow, inflow = transfer_legs(from: accounts(:depository), to: accounts(:loan), status: "confirmed")

    assert outflow.reload.category_editable?
    assert_not inflow.reload.category_editable?
    assert inflow.category_set_on_transfer_outflow?
  end

  test "a plain confirmed transfer takes no category on either leg" do
    outflow, inflow = transfer_legs(from: accounts(:depository), to: accounts(:connected), status: "confirmed")

    assert_not outflow.reload.category_editable?
    assert_not inflow.reload.category_editable?
    assert_not inflow.category_set_on_transfer_outflow?
  end

  test "both legs of a pending match keep their own category" do
    outflow, inflow = transfer_legs(from: accounts(:depository), to: accounts(:investment), status: "pending")

    assert outflow.reload.category_editable?
    assert inflow.reload.category_editable?
    assert_not inflow.category_set_on_transfer_outflow?
  end

  test "a matched inflow leg stays read-only after its kind is set to standard" do
    _outflow, inflow = transfer_legs(from: accounts(:depository), to: accounts(:investment), status: "confirmed")
    inflow.update_columns(kind: "standard")

    assert inflow.reload.category_set_on_transfer_outflow?
    assert_not inflow.category_editable?
  end

  test "a transfer kind without a transfer stays editable and payment? falls back to the kind" do
    assert Transaction.new(kind: "funds_movement").category_editable?
    assert Transaction.new(kind: "cc_payment").payment?
    assert_not Transaction.new(kind: "funds_movement").payment?
  end

  test "payment? follows the transfer over a stale leg kind" do
    outflow, _inflow = transfer_legs(from: accounts(:depository), to: accounts(:connected), status: "confirmed")
    outflow.update_columns(kind: "cc_payment")

    assert_not outflow.reload.payment?
  end

  private
    def transfer_legs(from:, to:, status:)
      outflow = Transaction.new
      from.entries.create!(name: "Out", date: Date.current, amount: 500, currency: from.currency, entryable: outflow)
      inflow = Transaction.new
      to.entries.create!(name: "In", date: Date.current, amount: -500, currency: to.currency, entryable: inflow)
      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: status)
      [ outflow, inflow ]
    end
end
