require "test_helper"

class RecurringTransaction::ReconcilerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # An account of its own, so fixture entries are never candidates
    @account = @family.accounts.create!(name: "Reconcile card", balance: 0, currency: "USD", accountable: Depository.new)
    @merchant = merchants(:netflix)
    @recurring = @family.recurring_transactions.create!(
      merchant: @merchant, amount: 100, currency: "USD", expected_day_of_month: 10,
      last_occurrence_date: 20.days.ago.to_date, next_expected_date: 10.days.from_now.to_date,
      status: "active", subscription_state: "subscription", default_account: @account,
      category: categories(:subscriptions)
    )
    @generated = generated_charge(date: 20.days.ago.to_date)
  end

  test "a generated charge then its real charge (same merchant, +10%, +2 days) is replaced" do
    real = real_charge(days: 2, amount: 110)

    result = reconcile

    assert_equal [ [ @generated.id, real.id ] ], result.replaced.map { |pair| [ pair.generated_entry.id, pair.real_entry.id ] }
    assert_empty result.flagged
    assert_not Entry.exists?(@generated.id)

    real.reload
    assert_equal @recurring.id, real.transaction.recurring_transaction_id
    stored = real.transaction.replaced_subscription_charge
    assert_equal @generated.id, stored["entry_id"]
    assert_equal @generated.date.iso8601, stored["date"]
    assert_equal "100.0", stored["amount"]
    assert_equal @recurring.id, stored["recurring_transaction_id"]
  end

  test "amount at 14.9% is replaced and at 15.1% is flagged" do
    near = real_charge(days: 1, amount: 114.9)
    assert_equal [ near.id ], reconcile(dry_run: true).replaced.map { |pair| pair.real_entry.id }

    near.destroy!
    far = real_charge(days: 1, amount: 115.1)
    result = reconcile(dry_run: true)
    assert_empty result.replaced
    assert_equal [ far.id ], result.flagged.map { |pair| pair.real_entry.id }
  end

  test "5 days apart is replaced and 6 days apart is flagged" do
    near = real_charge(days: 5)
    assert_equal [ near.id ], reconcile(dry_run: true).replaced.map { |pair| pair.real_entry.id }

    near.destroy!
    far = real_charge(days: -6)
    result = reconcile(dry_run: true)
    assert_empty result.replaced
    assert_equal [ far.id ], result.flagged.map { |pair| pair.real_entry.id }
  end

  test "amount +20% is flagged, not replaced" do
    real = real_charge(days: 1, amount: 120)

    result = reconcile

    assert_empty result.replaced
    assert Entry.exists?(@generated.id)
    transaction = @generated.reload.transaction
    assert transaction.has_potential_duplicate?
    assert transaction.subscription_charge_duplicate?
    assert_equal real.id, transaction.potential_duplicate_entry.id
    assert_nil real.reload.transaction.recurring_transaction_id
  end

  test "7 days apart is flagged, not replaced" do
    real_charge(days: 7)

    result = reconcile

    assert_empty result.replaced
    assert_equal [ @generated.id ], result.flagged.map { |pair| pair.generated_entry.id }
  end

  test "the same amount within 5 days without a service match is flagged" do
    real = real_charge(days: 1, merchant: nil, name: "CARD PAYMENT 4411")

    result = reconcile

    assert_empty result.replaced
    assert_equal [ real.id ], result.flagged.map { |pair| pair.real_entry.id }
  end

  test "a name that contains the subscription name is the same service" do
    real = real_charge(days: 1, merchant: nil, name: "NETFLIX.COM AMSTERDAM", amount: 103)

    assert_equal [ real.id ], reconcile(dry_run: true).replaced.map { |pair| pair.real_entry.id }
  end

  test "two candidates are flagged" do
    first = real_charge(days: 1)
    real_charge(days: 3)

    result = reconcile

    assert_empty result.replaced
    assert_equal [ first.id ], result.flagged.map { |pair| pair.real_entry.id }
    assert Entry.exists?(@generated.id)
  end

  test "one real charge near two generated charges is flagged" do
    second = generated_charge(date: @generated.date + 4.days)
    real_charge(days: 2)

    result = reconcile

    assert_empty result.replaced
    assert_equal [ @generated.id, second.id ].sort, result.flagged.map { |pair| pair.generated_entry.id }.sort
  end

  test "another merchant, a transfer and an opposite sign are left alone" do
    real_charge(days: 1, merchant: merchants(:amazon), name: "Amazon", amount: 140)
    real_charge(days: 1, kind: "funds_movement", amount: 100)
    real_charge(days: 1, amount: -100)

    result = reconcile

    assert_empty result.proposals
    assert_not @generated.reload.transaction.has_potential_duplicate?
  end

  test "a dismissed flag is not flagged again" do
    real_charge(days: 1, amount: 120)
    reconcile
    @generated.reload.transaction.dismiss_duplicate_suggestion!

    result = reconcile

    assert_empty result.proposals
    assert @generated.reload.transaction.potential_duplicate_dismissed?
  end

  test "category, tags and notes carry over to the real charge" do
    real = real_charge(days: 2, category: nil, notes: "paid by card")

    reconcile

    real.reload
    assert_equal categories(:subscriptions), real.transaction.category
    assert_equal [ tags(:one) ], real.transaction.tags.to_a
    assert_equal "paid by card\n\nFamily plan", real.notes
    assert_equal({ "category" => true, "tag_ids" => [ tags(:one).id ], "notes" => "Family plan" },
                 real.transaction.replaced_subscription_charge["carried_over"])
  end

  test "a real charge keeps its own category" do
    real = real_charge(days: 2, category: categories(:food_and_drink))

    reconcile

    assert_equal categories(:food_and_drink), real.reload.transaction.category
    assert_equal false, real.transaction.replaced_subscription_charge.dig("carried_over", "category")
  end

  test "dry_run writes nothing" do
    real = real_charge(days: 2)
    second = generated_charge(date: 60.days.ago.to_date)
    real_charge(days: 1, amount: 130, from: second.date)

    result = nil
    assert_no_difference [ -> { Entry.count }, -> { DebugLogEntry.count } ] do
      result = reconcile(dry_run: true)
    end

    assert_equal [ [ @generated.id, real.id ] ], result.replaced.map { |pair| [ pair.generated_entry.id, pair.real_entry.id ] }
    assert_equal [ second.id ], result.flagged.map { |pair| pair.generated_entry.id }
    assert_nil real.reload.transaction.recurring_transaction_id
    assert_nil second.reload.transaction.extra["potential_posted_match"]
  end

  test "a replace writes one debug log entry" do
    real = real_charge(days: 2)

    assert_difference -> { DebugLogEntry.where(category: "recurring_reconcile").count }, 1 do
      reconcile
    end

    log = DebugLogEntry.where(category: "recurring_reconcile").recent.first
    assert_equal "info", log.level
    assert_equal @generated.id, log.metadata["generated_entry_id"]
    assert_equal real.id, log.metadata["real_entry_id"]
  end

  test "a replace does not move next_expected_date" do
    real_charge(days: 2)

    assert_no_changes -> { @recurring.reload.next_expected_date } do
      reconcile
    end
  end

  test "a generated charge older than the lookback is left alone" do
    old = generated_charge(date: (RecurringTransaction::Reconciler::LOOKBACK_DAYS + 5).days.ago.to_date)
    real_charge(days: 1, from: old.date)

    assert_not_includes reconcile(dry_run: true).proposals.map { |pair| pair.generated_entry.id }, old.id
  end

  private
    def reconcile(dry_run: false)
      RecurringTransaction::Reconciler.new(@family, dry_run: dry_run).reconcile
    end

    def generated_charge(date:, amount: 100)
      @account.entries.create!(
        date: date, amount: amount, currency: "USD", name: "Netflix", notes: "Family plan", source: "subscription",
        entryable: Transaction.new(category: categories(:subscriptions), merchant: @merchant, recurring_transaction: @recurring, tags: [ tags(:one) ])
      )
    end

    def real_charge(days:, amount: 100, merchant: @merchant, name: "NETFLIX", kind: "standard", category: nil, notes: nil, from: @generated.date)
      @account.entries.create!(
        date: from + days.days, amount: amount, currency: "USD", name: name, notes: notes,
        entryable: Transaction.new(merchant: merchant, kind: kind, category: category)
      )
    end
end
