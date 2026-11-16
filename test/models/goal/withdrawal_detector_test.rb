require "test_helper"

# Ported from upstream (goal-spending). Fork cases at the end: transfers between own
# accounts are not spending, the window is three fiscal months, and the threshold is
# converted into each account's currency.
class Goal::WithdrawalDetectorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    ExchangeRate.stubs(:provider).returns(nil)
    @account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Trip Pot #{SecureRandom.hex(4)}", currency: "USD", balance: 5_000
    )
    @goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: @account, allocated_amount: 5_000)
    end
  end

  test "surfaces an outflow nothing has claimed" do
    entry = outflow(1_200)

    assert_equal [ entry.id ], detect.map(&:id)
  end

  # In Sure an inflow carries a NEGATIVE amount. Reading the sign the other way
  # round would offer to attribute the user's own deposits as spending.
  test "never surfaces an inflow" do
    outflow(-1_200)

    assert_empty detect
  end

  test "ignores an outflow below the threshold" do
    outflow(Goal::WithdrawalDetector::MIN_AMOUNT.amount - 1)

    assert_empty detect
  end

  test "ignores an outflow the user excluded" do
    outflow(1_200).update!(excluded: true)

    assert_empty detect
  end

  test "ignores an outflow older than the window" do
    outflow(1_200, date: detector.window_start - 1.day)

    assert_empty detect
  end

  test "stops offering an outflow once it has been attributed" do
    entry = outflow(1_200)
    assert_equal [ entry.id ], detect.map(&:id)

    @goal.consume!(1_200, transaction: entry.entryable)

    assert_empty detect
  end

  # A reserve is drawn down and refilled, not spent. Asking the user to
  # attribute a withdrawal from one would invite them to erase the shortfall
  # the reserve exists to report.
  test "says nothing for a reserve" do
    reserve_account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Reserve Pot", currency: "USD", balance: 4_000
    )
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained"
    ) { |g| g.goal_accounts.build(account: reserve_account) }
    create_outflow(reserve_account, 1_200, Date.current)

    assert_empty Goal::WithdrawalDetector.new(reserve).unattributed_outflows
  end

  test "an outflow on an account this goal does not fund is not its business" do
    other = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Other Pot", currency: "USD", balance: 5_000
    )
    create_outflow(other, 1_200, Date.current)

    assert_empty detect
  end

  test "newest first, capped" do
    older = outflow(1_000, date: 10.days.ago.to_date)
    newest = outflow(2_000, date: 1.day.ago.to_date)
    middle = outflow(3_000, date: 5.days.ago.to_date)

    assert_equal [ newest.id, middle.id ], detect(limit: 2).map(&:id)
    assert_includes detect(limit: 3).map(&:id), older.id
  end

  # --- Review follow-ups ---

  # A released goal has handed its accounts back, so a later outflow on one of
  # them is not evidence about this goal. Offering it invites the user to write
  # spending into a history that is already closed.
  test "says nothing once the goal has been released" do
    entry = outflow(1_200)
    assert_equal [ entry.id ], detect.map(&:id)

    @goal.complete!

    assert_empty detect
  end

  test "says nothing for an archived goal" do
    outflow(1_200)
    @goal.archive!

    assert_empty detect
  end

  # A provisional charge can still be reversed, or replaced by its posted form.
  # Attributing one leaves the goal consumed for a transaction that no longer
  # exists, while the posted twin arrives unstamped and is offered all over.
  test "ignores an outflow the provider has not posted yet" do
    entry = outflow(1_200)
    entry.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    assert_empty detect
  end

  test "still surfaces an outflow the provider has posted" do
    entry = outflow(1_200)
    entry.entryable.update!(extra: { "simplefin" => { "pending" => false } })

    assert_equal [ entry.id ], detect.map(&:id)
  end

  # --- Fork rules ---

  # Moving savings to the card is not the spend: the purchase on the card is
  test "a transfer to another own account is not a withdrawal" do
    checking = Account.create!(family: @family, accountable: Depository.new,
                               name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: 0)
    transfer = Transfer::Creator.new(
      family: @family, source_account_id: @account.id, destination_account_id: checking.id,
      date: Date.current, amount: 1_500
    ).create
    assert transfer.persisted?, transfer.errors.full_messages.to_sentence
    assert_equal "funds_movement", transfer.outflow_transaction.reload.kind

    assert_empty detect
  end

  test "a card payment from the goal's account is not a withdrawal either" do
    entry = outflow(1_200)
    entry.entryable.update_columns(kind: "cc_payment")

    assert_empty detect
  end

  test "the window is the current budget month and the two before it" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    today = Date.new(2026, 11, 3)

    detector = Goal::WithdrawalDetector.new(@goal, today: today)

    # 3 Nov sits in the month that started on 5 Oct, so the window opens on 5 Aug
    assert_equal Date.new(2026, 8, 5), detector.window_start
  end

  test "an outflow just inside the fiscal window is offered, one a day earlier is not" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    today = Date.new(2026, 11, 3)
    inside = outflow(1_200, date: Date.new(2026, 8, 5))
    outflow(1_300, date: Date.new(2026, 8, 4))

    travel_to today do
      found = Goal::WithdrawalDetector.new(@goal, today: today).unattributed_outflows(limit: 10)
      assert_equal [ inside.id ], found.map(&:id)
    end
  end

  # 100 USD worth, not 100 units: for a UAH account the bar is in hryvnias
  test "the threshold is converted into the account's currency" do
    uah = Account.create!(family: @family, accountable: Depository.new,
                          name: "UAH Pot #{SecureRandom.hex(3)}", currency: "UAH", balance: 100_000)
    goal = @family.goals.create!(name: "Hryvnia trip", target_amount: 100_000, currency: "UAH") do |g|
      g.goal_accounts.build(account: uah, allocated_amount: 100_000)
    end
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current, rate: 41)
    small = create_outflow(uah, 4_000, Date.current)
    large = create_outflow(uah, 4_200, Date.current)

    found = Goal::WithdrawalDetector.new(goal).unattributed_outflows(limit: 10).map(&:id)

    assert_includes found, large.id
    assert_not_includes found, small.id
  end

  # A split transaction is one outflow: its parent, never its parts
  test "a split outflow is offered once, as the whole" do
    entry = outflow(1_200)
    entry.split!([ { name: "Hotel", amount: 700 }, { name: "Flights", amount: 500 } ])

    assert_equal [ entry.id ], detect(limit: 10).map(&:id)
  end

  test "an outflow already spent from the goal is not offered again after it is split" do
    entry = outflow(1_200)
    @goal.consume!(1_200, transaction: entry.entryable)

    entry.reload.split!([ { name: "Hotel", amount: 700 }, { name: "Flights", amount: 500 } ])

    assert_empty detect(limit: 10)
    assert_equal 1_200, @goal.reload.consumed_amount.to_d
  end

  test "spending a part claims its split, so an unsplit does not offer the whole again" do
    entry = outflow(1_200)
    entry.split!([ { name: "Hotel", amount: 700 }, { name: "Flights", amount: 500 } ])
    hotel = entry.reload.child_entries.find_by!(name: "Hotel")

    @goal.consume!(700, transaction: hotel.entryable)
    assert_equal @goal.id, entry.transaction.reload.extra.dig("goal", "consumed_goal_id")

    entry.reload.unsplit!

    assert_empty detect(limit: 10)
    assert_equal 700, @goal.reload.consumed_amount.to_d
  end

  test "a part stamped before claims moved to the split still claims it, and hands the claim over on unsplit" do
    entry = outflow(1_200)
    entry.split!([ { name: "Hotel", amount: 700 }, { name: "Flights", amount: 500 } ])
    hotel = entry.reload.child_entries.find_by!(name: "Hotel")
    hotel.entryable.update_columns(extra: { "goal" => { "consumed_goal_id" => @goal.id } })

    assert_empty detect(limit: 10)

    entry.reload.unsplit!

    assert_equal @goal.id, entry.transaction.reload.extra.dig("goal", "consumed_goal_id")
    assert_empty detect(limit: 10)
  end

  private
    def detect(limit: 3)
      detector.unattributed_outflows(limit: limit)
    end

    def detector
      Goal::WithdrawalDetector.new(@goal)
    end

    def outflow(amount, date: Date.current)
      create_outflow(@account, amount, date)
    end

    def create_outflow(account, amount, date)
      account.entries.create!(
        name: "Spend #{SecureRandom.hex(3)}",
        date: date,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new
      )
    end
end
