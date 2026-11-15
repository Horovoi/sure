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

  # ---------------------------------------------------------------------------
  # Generated subscription charges and their real charges
  # ---------------------------------------------------------------------------

  test "flag_potential_duplicate! keeps the first suggestion" do
    first = subscription_test_setup[:real]
    generated = @sub_generated.transaction
    second = @sub_account.entries.create!(date: first.date, amount: 50, currency: "USD", name: "Other", entryable: Transaction.new)

    assert generated.flag_potential_duplicate!(posted_entry: first, reason: "subscription_charge", posted_amount: first.amount)
    assert_not generated.flag_potential_duplicate!(posted_entry: second, reason: "subscription_charge", posted_amount: second.amount)
    assert_equal first.id, generated.reload.potential_duplicate_entry.id
  end

  test "merge_with_duplicate! for a subscription charge links the real charge and deletes only the generated one" do
    pair = subscription_test_setup
    real = pair[:real]
    generated_transaction = @sub_generated.transaction
    generated_transaction.flag_potential_duplicate!(posted_entry: real, reason: "subscription_charge", posted_amount: real.amount)

    assert_difference -> { Entry.count }, -1 do
      assert generated_transaction.reload.merge_with_duplicate!
    end

    assert_not Entry.exists?(@sub_generated.id)
    assert Entry.exists?(real.id)
    real_transaction = real.reload.transaction
    assert_equal @sub_recurring.id, real_transaction.recurring_transaction_id
    assert_equal categories(:subscriptions), real_transaction.category
    assert_equal [ tags(:one) ], real_transaction.tags.to_a
    assert_equal "Family plan", real.notes

    stored = real_transaction.replaced_subscription_charge
    assert_equal @sub_generated.id, stored["entry_id"]
    assert_equal @sub_generated.date.iso8601, stored["date"]
    assert_equal "100.0", stored["amount"]
    assert_equal "USD", stored["currency"]
    assert_equal "Netflix", stored["name"]
    assert_equal categories(:subscriptions).id, stored["category_id"]
    assert_equal merchants(:netflix).id, stored["merchant_id"]
    assert_equal [ tags(:one).id ], stored["tag_ids"]
    assert_equal "Family plan", stored["notes"]
    assert_equal @sub_recurring.id, stored["recurring_transaction_id"]
  end

  test "restore_replaced_subscription_charge! inserts the generated charge again and keeps next_expected_date" do
    real = subscription_test_setup[:real]
    real.transaction.replace_subscription_charge!(@sub_generated, source: "test")
    next_expected = @sub_recurring.reload.next_expected_date

    assert_difference -> { Entry.count }, 1 do
      assert_equal :restored, real.reload.transaction.restore_replaced_subscription_charge!
    end

    restored = @sub_account.entries.where(source: "subscription").sole
    assert_equal @sub_generated.date, restored.date
    assert_equal 100, restored.amount
    assert_equal "Netflix", restored.name
    assert_equal "Family plan", restored.notes
    assert_equal @sub_recurring.id, restored.transaction.recurring_transaction_id
    assert_equal categories(:subscriptions), restored.transaction.category
    assert_equal merchants(:netflix), restored.transaction.merchant
    assert_equal [ tags(:one) ], restored.transaction.tags.to_a
    # Marked as not this real charge, so the reconciler leaves the pair alone
    assert restored.transaction.potential_duplicate_dismissed?

    real.reload
    assert_not real.transaction.replaced_subscription_charge?
    assert_nil real.transaction.recurring_transaction_id
    assert_nil real.transaction.category
    assert_empty real.transaction.tags
    assert_nil real.notes
    assert_equal next_expected, @sub_recurring.reload.next_expected_date
  end

  test "restore is skipped when the recurring row is gone or the period has a generated charge" do
    real = subscription_test_setup[:real]
    real.transaction.replace_subscription_charge!(@sub_generated, source: "test")

    @sub_account.entries.create!(
      date: @sub_generated.date, amount: 100, currency: "USD", name: "Netflix", source: "subscription",
      entryable: Transaction.new(recurring_transaction: @sub_recurring)
    )
    assert_equal :period_taken, real.reload.transaction.restore_replaced_subscription_charge!

    Transaction.where(recurring_transaction_id: @sub_recurring.id).update_all(recurring_transaction_id: nil)
    @sub_recurring.destroy!
    assert_equal :recurring_missing, real.reload.transaction.restore_replaced_subscription_charge!
    assert real.transaction.replaced_subscription_charge?
  end

  test "replace_subscription_charge! refuses a real charge that already belongs to a recurring row" do
    real = subscription_test_setup[:real]
    real.transaction.update!(recurring_transaction: @sub_recurring)

    assert_no_difference -> { Entry.count } do
      assert_not real.transaction.replace_subscription_charge!(@sub_generated, source: "test")
    end
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

    def subscription_test_setup
      family = families(:dylan_family)
      @sub_account = family.accounts.create!(name: "Subscription card", balance: 0, currency: "USD", accountable: Depository.new)
      @sub_recurring = family.recurring_transactions.create!(
        merchant: merchants(:netflix), amount: 100, currency: "USD", expected_day_of_month: 10,
        last_occurrence_date: 20.days.ago.to_date, next_expected_date: 10.days.from_now.to_date,
        status: "active", subscription_state: "subscription", default_account: @sub_account
      )
      @sub_generated = @sub_account.entries.create!(
        date: 20.days.ago.to_date, amount: 100, currency: "USD", name: "Netflix", notes: "Family plan", source: "subscription",
        entryable: Transaction.new(category: categories(:subscriptions), merchant: merchants(:netflix), recurring_transaction: @sub_recurring, tags: [ tags(:one) ])
      )
      real = @sub_account.entries.create!(
        date: 18.days.ago.to_date, amount: 104, currency: "USD", name: "NETFLIX.COM", entryable: Transaction.new(merchant: merchants(:netflix))
      )
      { real: real }
    end
end
