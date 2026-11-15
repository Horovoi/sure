require "test_helper"

# goal-pledges. Ported from upstream; the status checks are the fork's AASM events, and
# the release cases (a deleted transaction gives the pledge back) are new.
class GoalPledgeTest < ActiveSupport::TestCase
  setup do
    ExchangeRate.stubs(:provider).returns(nil)
    @goal = goals(:vacation_italy)
    @account = accounts(:depository)
    @pledge = goal_pledges(:open_transfer)
  end

  test "valid fixture pledge saves" do
    assert @pledge.valid?
  end

  test "amount must be positive" do
    @pledge.amount = 0
    assert_not @pledge.valid?

    @pledge.amount = -5
    assert_not @pledge.valid?
    assert_includes @pledge.errors[:amount], "must be greater than 0"
  end

  test "account must be linked to goal" do
    pledge = @goal.goal_pledges.new(account: accounts(:investment), amount: 50, currency: "USD")
    assert_not pledge.valid?
    assert_includes pledge.errors[:account], "Pick one of the goal's linked accounts."
  end

  test "currency must match goal currency" do
    @pledge.currency = "EUR"
    assert_not @pledge.valid?
    assert_includes @pledge.errors[:currency], "Pledge currency must match the goal currency."
  end

  test "defaults come from the goal and the account" do
    pledge = @goal.goal_pledges.new(account: @account, amount: 50)
    pledge.valid?

    assert pledge.open?
    assert_equal "manual_save", pledge.kind, "a manual cash account is also kept by a balance update"
    assert pledge.expires_at > Time.current
    assert_equal @goal.currency, pledge.currency
  end

  test "an investment account pledges by transfer" do
    assert_equal "transfer", accounts(:investment).default_pledge_kind
    assert_equal "manual_save", @account.default_pledge_kind
  end

  test "matches? within the date and amount tolerances" do
    assert @pledge.matches?(entry_like(amount: -237.25, date: @pledge.created_at.to_date + 1.day))
    assert @pledge.matches?(entry_like(amount: -239.30, date: @pledge.created_at.to_date)), "within 1%"
  end

  test "matches? refuses outside the date window or the amount tolerance" do
    assert_not @pledge.matches?(entry_like(amount: -237, date: @pledge.created_at.to_date + 10.days))
    assert_not @pledge.matches?(entry_like(amount: -300, date: @pledge.created_at.to_date))
  end

  test "matches? refuses another account" do
    assert_not @pledge.matches?(entry_like(amount: -237, date: Date.current, account: accounts(:connected)))
  end

  # Sure stores an outflow as a positive amount. A 237 purchase must not keep it.
  test "matches? refuses an outflow of the same size" do
    assert_not @pledge.matches?(entry_like(amount: 237, date: Date.current))
  end

  test "matches? refuses a pledge that is no longer open" do
    matched = goal_pledges(:matched_transfer)
    assert_not matched.matches?(entry_like(amount: -matched.amount.to_d, date: Date.current, account: matched.account))
  end

  test "extending widens the window to the new expiry" do
    @pledge.extend!
    far_date = @pledge.created_at.to_date + 8.days
    assert far_date <= @pledge.expires_at.to_date

    assert @pledge.matches?(entry_like(amount: -237, date: far_date))
    assert_not @pledge.matches?(entry_like(amount: -237, date: @pledge.expires_at.to_date + 1.day))
  end

  test "extend! refuses a pledge that is not open" do
    assert_raises(GoalPledge::NotOpenError) { goal_pledges(:matched_transfer).extend! }
  end

  test "a second open pledge for the same amount on the same account is refused" do
    duplicate = @goal.goal_pledges.new(account: @account, amount: @pledge.amount, currency: @goal.currency)
    assert_not duplicate.valid?
    assert duplicate.errors[:base].any? { |message| message.include?("open pledge") }

    other_amount = @goal.goal_pledges.new(account: @account, amount: @pledge.amount.to_d + 1, currency: @goal.currency)
    assert other_amount.valid?, other_amount.errors.full_messages.to_sentence
  end

  # --- AASM transitions ---

  test "cancel moves an open pledge to cancelled" do
    @pledge.cancel!
    assert @pledge.reload.cancelled?
  end

  test "expire moves an open pledge to expired" do
    @pledge.expire!
    assert @pledge.reload.expired?
  end

  test "only an open pledge can be cancelled or expired" do
    @pledge.expire!

    assert_not @pledge.may_expire?
    assert_raises(AASM::InvalidTransition) { @pledge.cancel! }
    assert @pledge.reload.expired?
  end

  test "match is recorded with the transaction that kept it" do
    entry = inflow(237)
    @pledge.reload

    assert @pledge.matched?, "the manual inflow keeps the pledge on create"
    assert_equal entry.entryable.id, @pledge.matched_transaction_id
    assert_equal entry.date, @pledge.matched_on
    assert_equal @pledge.id, entry.entryable.reload.extra.dig("goal", "pledge_id")
  end

  test "deleting the transaction that kept it reopens the pledge and clears the match" do
    entry = inflow(237)
    assert @pledge.reload.matched?

    entry.destroy!

    @pledge.reload
    assert @pledge.open?
    assert_nil @pledge.matched_transaction_id
    assert_nil @pledge.matched_on
  end

  test "a pledge whose window has passed goes to expired instead" do
    entry = inflow(237)
    assert @pledge.reload.matched?

    travel 8.days do
      entry.destroy!
      assert @pledge.reload.expired?
    end
  end

  test "destroying a kept pledge takes its id off the transaction and keeps the other keys" do
    entry = inflow(237)
    txn = entry.entryable
    txn.update!(extra: txn.reload.extra.merge("exchange_rate" => { "rate" => "1.0" }))

    @pledge.reload.destroy!

    extra = txn.reload.extra
    assert_nil extra["goal"]
    assert_equal({ "rate" => "1.0" }, extra["exchange_rate"])
  end

  test "days_left counts down and is zero once not open" do
    @pledge.expires_at = 3.days.from_now
    assert_includes 2..3, @pledge.days_left
    assert_equal 0, goal_pledges(:matched_transfer).days_left
  end

  test "the goal counts open pledges toward the catch-up figure" do
    assert_equal 237, @goal.pending_pledged_amount
    assert_equal goals(:vacation_italy).goal_pledges.where(status: "matched").maximum(:matched_on), @goal.last_matched_pledge_on
  end

  private
    def entry_like(amount:, date:, account: @account)
      Entry.new(account: account, amount: BigDecimal(amount.to_s), currency: "USD", date: date.to_date, entryable: Transaction.new)
    end

    def inflow(amount, date: Date.current)
      @account.entries.create!(name: "Savings in", date: date, amount: -amount, currency: "USD", entryable: Transaction.new)
    end
end
