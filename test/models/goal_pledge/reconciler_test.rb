require "test_helper"

# goal-pledges. Ported from upstream and extended for the fork's manual paths: the
# transaction create hook, transfers, balance updates (reconciliation and the opening
# balance adjustment), import publish and revert, and family isolation.
class GoalPledge::ReconcilerTest < ActiveSupport::TestCase
  setup do
    ExchangeRate.stubs(:provider).returns(nil)
    @family = families(:dylan_family)
    @account = Account.create!(family: @family, accountable: Depository.new,
                               name: "Pledge Pot #{SecureRandom.hex(3)}", currency: "USD", balance: 2_000)
    @goal = @family.goals.create!(name: "Trip", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: @account, allocated_amount: 2_000)
    end
    @pledge = @goal.goal_pledges.create!(account: @account, amount: 200)
  end

  test "a manual inflow keeps the pledge when it is created" do
    entry = inflow(200)

    assert @pledge.reload.matched?
    assert_equal entry.entryable.id, @pledge.matched_transaction_id
    assert_equal @pledge.id, entry.entryable.reload.extra.dig("goal", "pledge_id")
  end

  test "a transfer into the account keeps the pledge, within the amount tolerance" do
    checking = Account.create!(family: @family, accountable: Depository.new,
                               name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: 1_000)

    transfer = Transfer::Creator.new(
      family: @family, source_account_id: checking.id, destination_account_id: @account.id,
      date: Date.current, amount: 201.5
    ).create

    assert transfer.persisted?, transfer.errors.full_messages.to_sentence
    assert @pledge.reload.matched?
    assert_equal transfer.inflow_transaction.id, @pledge.matched_transaction_id
  end

  test "an inflow outside the tolerance leaves the pledge open" do
    entry = inflow(300)

    GoalPledge::Reconciler.new(entry).run

    assert @pledge.reload.open?
    assert_nil entry.entryable.reload.extra.dig("goal", "pledge_id")
  end

  test "an entry already stamped with a pledge keeps no other" do
    entry = @account.entries.create!(
      name: "Savings in", date: Date.current, amount: -200, currency: "USD",
      entryable: Transaction.new(extra: { "goal" => { "pledge_id" => "abc" } })
    )

    assert_nil GoalPledge::Reconciler.new(entry).run
    assert_equal "abc", entry.entryable.reload.extra.dig("goal", "pledge_id")
    assert @pledge.reload.open?
  end

  # One inflow keeps one pledge: the older one first, the second stays open
  test "no double match: one inflow keeps only the oldest of two close pledges" do
    second = @goal.goal_pledges.create!(account: @account, amount: 200.5)
    entry = inflow(200)

    assert @pledge.reload.matched?
    assert second.reload.open?

    GoalPledge::Reconciler.new(entry).run
    assert second.reload.open?, "running again must not let the same inflow keep a second pledge"
  end

  test "an excluded inflow keeps nothing" do
    entry = @account.entries.create!(name: "Savings in", date: Date.current, amount: -200, currency: "USD",
                                     excluded: true, entryable: Transaction.new)

    GoalPledge::Reconciler.new(entry).run

    assert @pledge.reload.open?
  end

  test "an entry of another family's account keeps nothing" do
    other = Account.create!(family: families(:empty), accountable: Depository.new,
                            name: "Other Pot", currency: "USD", balance: 0)
    entry = other.entries.create!(name: "In", date: Date.current, amount: -200, currency: "USD", entryable: Transaction.new)

    GoalPledge::Reconciler.new(entry).run

    assert @pledge.reload.open?
  end

  test "a pledge on an account the goal no longer uses is not kept" do
    second = Account.create!(family: @family, accountable: Depository.new,
                             name: "Second #{SecureRandom.hex(3)}", currency: "USD", balance: 0)
    @goal.goal_accounts.create!(account: second, allocated_amount: 0)
    @goal.goal_accounts.find_by!(account: @account).delete

    inflow(200)

    assert @pledge.reload.open?
  end

  # --- Balance updates ---

  test "a reconciliation keeps a manual_save pledge by the balance change, not the full balance" do
    assert_equal "manual_save", @pledge.kind
    @account.balances.create!(date: Date.current, balance: 2_000, cash_balance: 2_000, currency: "USD")

    result = Account::ReconciliationManager.new(@account).reconcile_balance(balance: 2_200, date: Date.current)

    assert result.success?, result.error_message
    assert @pledge.reload.matched?
    assert_nil @pledge.matched_transaction_id
    assert_equal Date.current, @pledge.matched_on
  end

  test "a valuation is matched by its delta, never by its full amount" do
    entry = valuation(2_150)

    GoalPledge::Reconciler.new(entry, valuation_delta: 2_150).run

    assert @pledge.reload.open?
  end

  test "a balance that fell keeps nothing" do
    entry = valuation(1_800)

    GoalPledge::Reconciler.new(entry, valuation_delta: -200).run

    assert @pledge.reload.open?
  end

  test "a balance update never keeps a transfer pledge" do
    @pledge.update_columns(kind: "transfer")
    entry = valuation(2_200)

    GoalPledge::Reconciler.new(entry, valuation_delta: 200).run

    assert @pledge.reload.open?
  end

  test "a balance update on an investment account keeps nothing" do
    brokerage = Account.create!(family: @family, accountable: Investment.new,
                                name: "Brokerage #{SecureRandom.hex(3)}", currency: "USD", balance: 5_000)
    @goal.goal_accounts.create!(account: brokerage, allocated_amount: 1_000)
    pledge = @goal.goal_pledges.create!(account: brokerage, amount: 300)
    pledge.update_columns(kind: "manual_save")
    entry = brokerage.entries.create!(name: "Value", date: Date.current, amount: 5_300, currency: "USD",
                                      entryable: Valuation.new(kind: "reconciliation"))

    GoalPledge::Reconciler.new(entry, valuation_delta: 300).run

    assert pledge.reload.open?
  end

  # record_balance on a cash account with no reconciliations moves the opening balance
  # instead of writing a reconciliation dated today
  test "a balance update that adjusts the opening balance keeps the pledge too" do
    Account::CurrentBalanceManager.any_instance.stubs(:derived_current_balance).returns(2_000.to_d)

    result = @account.set_current_balance(2_200)

    assert result.success?, result.error
    assert @pledge.reload.matched?
  end

  # --- Imports ---

  test "publishing an import keeps a pledge with a bulk-inserted inflow" do
    import = csv_import("#{Date.current.strftime('%m/%d/%Y')},Savings in,-200")

    import.publish

    assert import.reload.complete?, import.error
    assert @pledge.reload.matched?
    assert_equal import.entries.first.entryable_id, @pledge.matched_transaction_id
  end

  test "reverting the import reopens the pledge" do
    import = csv_import("#{Date.current.strftime('%m/%d/%Y')},Savings in,-200")
    import.publish
    assert @pledge.reload.matched?

    import.revert_later
    import.revert

    assert import.reload.reverted?
    assert @pledge.reload.open?
    assert_nil @pledge.matched_transaction_id
  end

  private
    def inflow(amount, date: Date.current)
      @account.entries.create!(name: "Savings in", date: date, amount: -amount, currency: "USD", entryable: Transaction.new)
    end

    def valuation(amount)
      @account.entries.create!(name: "Manual balance", date: Date.current, amount: amount, currency: "USD",
                               entryable: Valuation.new(kind: "reconciliation"))
    end

    def csv_import(row)
      import = @family.imports.create!(type: "TransactionImport", account: @account)
      import.update!(
        raw_file_str: "date,name,amount\n#{row}\n",
        date_col_label: "date",
        amount_col_label: "amount",
        name_col_label: "name",
        date_format: "%m/%d/%Y",
        amount_type_strategy: "signed_amount",
        signage_convention: "inflows_negative"
      )
      import.generate_rows_from_csv
      import.sync_mappings
      import.reload
    end
end
