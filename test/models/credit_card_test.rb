require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  include BalanceTestHelper

  # -- Configuration -----------------------------------------------------------

  test "statement cycle days are a real day of the month" do
    card = CreditCard.new

    card.statement_close_day = 0
    assert_not card.valid?
    assert card.errors[:statement_close_day].present?

    card.statement_close_day = 32
    assert_not card.valid?
    assert card.errors[:statement_close_day].present?

    card.statement_close_day = 31
    card.due_day = 31
    assert card.valid?

    card.statement_close_day = nil
    card.due_day = nil
    assert card.valid?
  end

  test "the database refuses a day outside 1..31" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_raises(ActiveRecord::StatementInvalid) { card.update_column(:statement_close_day, 32) }
  end

  test "a card without an account or a close day has no cycle" do
    assert_not CreditCard.new(statement_close_day: 25, due_day: 5).statement_cycle_configured?

    card = CreditCard.new(due_day: 5)
    card.account = accounts(:credit_card)

    assert_not card.statement_cycle_configured?
    assert_nil card.last_statement_close_date
    assert_nil card.next_statement_close_date
    assert_nil card.next_payment_due_date
    assert_nil card.days_until_due
    assert_nil card.last_statement_balance_money
    assert_nil card.accrued_since_last_close_money
    assert_nil card.statement_summary
  end

  test "a close day without a due day closes but is never due" do
    card = CreditCard.new(statement_close_day: 25)
    card.account = accounts(:credit_card)

    assert_equal Date.new(2026, 10, 25), card.next_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_nil card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
  end

  # -- Statement windows -------------------------------------------------------

  test "the last close is the close on or before the date" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 9, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 9, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 24))
    assert_equal Date.new(2026, 10, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 25))
  end

  test "the previous close is one cycle back and the next close one cycle on" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 8, 25), card.previous_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 10, 25), card.next_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2027, 1, 25), card.next_statement_close_date(as_of: Date.new(2026, 12, 31))
  end

  test "close day 31 moves to the last day of a shorter month and goes back to 31 after it" do
    card = statement_card(close_day: 31, due_day: 20)

    assert_equal Date.new(2026, 10, 31), card.last_statement_close_date(as_of: Date.new(2026, 11, 3))
    assert_equal Date.new(2026, 11, 30), card.next_statement_close_date(as_of: Date.new(2026, 11, 3))
    assert_equal Date.new(2027, 2, 28), card.last_statement_close_date(as_of: Date.new(2027, 3, 1))
    assert_equal Date.new(2028, 2, 29), card.last_statement_close_date(as_of: Date.new(2028, 3, 1))

    # February clamps to the 28th; the next close is 31 March, not 28 March
    assert_equal Date.new(2027, 3, 31), card.next_statement_close_date(as_of: Date.new(2027, 3, 1))
    assert_equal Date.new(2027, 1, 31), card.previous_statement_close_date(as_of: Date.new(2027, 3, 1))
  end

  # -- Due dates ---------------------------------------------------------------

  test "a due day before the close day is in the next month" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 11, 5), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_equal 20, card.days_until_due(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2027, 1, 5), card.payment_due_date_for(Date.new(2026, 12, 25))
  end

  test "a due day after the close day is in the same month" do
    card = statement_card(close_day: 10, due_day: 26)

    assert_equal Date.new(2026, 10, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_equal 10, card.days_until_due(as_of: Date.new(2026, 10, 16))
  end

  test "a card is due today on the due date" do
    card = statement_card(close_day: 10, due_day: 26)

    assert_equal 0, card.days_until_due(as_of: Date.new(2026, 10, 26))
  end

  test "due day 31 moves to the end of February" do
    card = statement_card(close_day: 10, due_day: 31)

    assert_equal Date.new(2027, 2, 28), card.payment_due_date_for(Date.new(2027, 2, 10))
    assert_equal Date.new(2027, 3, 31), card.payment_due_date_for(Date.new(2027, 3, 10))
  end

  test "a due day before the close day stays in the next month when February puts both on one day" do
    card = statement_card(close_day: 31, due_day: 28)

    # The statement that closed on 28 February is due on 28 March
    assert_equal Date.new(2026, 2, 28), card.last_statement_close_date(as_of: Date.new(2026, 3, 1))
    assert_equal Date.new(2026, 3, 28), card.payment_due_date_for(Date.new(2026, 2, 28))
    assert_equal Date.new(2026, 3, 28), card.next_payment_due_date(as_of: Date.new(2026, 3, 1))
  end

  test "an unpaid statement stays overdue after its due date" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 300)

    assert_equal Date.new(2026, 10, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 27))
    assert_equal(-1, card.days_until_due(as_of: Date.new(2026, 10, 27)))
  end

  test "a partly paid statement keeps its due date" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 300)
    charge(card.account, Date.new(2026, 10, 20), -100)

    assert_equal Date.new(2026, 10, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 27))
  end

  test "a paid statement gives way to the next one after its due date" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 300)
    charge(card.account, Date.new(2026, 10, 20), -300)

    assert_equal Date.new(2026, 11, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 27))
    assert_equal 30, card.days_until_due(as_of: Date.new(2026, 10, 27))
  end

  test "a statement with nothing owed gives way after its due date" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 0)

    assert_equal Date.new(2026, 11, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 27))
  end

  # -- Statement balances ------------------------------------------------------

  test "the statement balance is what the card owed at the close" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account

    create_balance(account: account, date: Date.new(2026, 8, 1), balance: 1_999)
    create_balance(account: account, date: Date.new(2026, 9, 25), balance: 2_059)
    create_balance(account: account, date: Date.new(2026, 9, 26), balance: 2_559) # the next statement

    statement = card.last_statement_balance_money(as_of: Date.new(2026, 10, 16))

    assert_equal 2_059, statement.amount
    assert_equal "USD", statement.currency.iso_code
    assert_equal 500, card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16)).amount
  end

  test "the last balance before the close carries to the close" do
    card = statement_card(close_day: 25, due_day: 5)
    create_balance(account: card.account, date: Date.new(2026, 9, 10), balance: 100)

    assert_equal 100, card.last_statement_balance_money(as_of: Date.new(2026, 10, 16)).amount
    assert_equal 0, card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16)).amount
  end

  test "a statement before the card's history is zero, and a card with no balances is unknown" do
    card = statement_card(close_day: 25, due_day: 5, history: false)

    assert_nil card.last_statement_balance_money(as_of: Date.new(2026, 10, 16))
    assert_nil card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16))

    create_balance(account: card.account, date: Date.new(2026, 10, 1), balance: 80)

    assert_equal 0, card.last_statement_balance_money(as_of: Date.new(2026, 10, 16)).amount
    assert_equal 80, card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16)).amount
  end

  test "a balance in another currency is not the card's balance" do
    card = statement_card(close_day: 25, due_day: 5, history: false)
    create_balance(account: card.account, date: Date.new(2026, 9, 1), balance: 100, currency: "EUR")

    assert_nil card.last_statement_balance_money(as_of: Date.new(2026, 10, 16))
  end

  test "the minimum payment shortfall reads against the statement balance" do
    card = statement_card(close_day: 25, due_day: 5, minimum_payment: 100)
    create_balance(account: card.account, date: Date.new(2026, 9, 1), balance: 400)

    assert card.minimum_payment_shortfall?(as_of: Date.new(2026, 10, 16))

    card.update!(minimum_payment: nil)
    assert_not card.minimum_payment_shortfall?(as_of: Date.new(2026, 10, 16))
  end

  # -- Statement summary -------------------------------------------------------

  test "the summary splits the cycle into charges and credits from transactions only" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account
    as_of = Date.new(2026, 10, 4)

    create_balance(account: account, date: Date.new(2026, 9, 25), balance: 300)
    charge(account, Date.new(2026, 9, 25), 70) # on the close day: the closed statement
    charge(account, Date.new(2026, 9, 28), 120)
    charge(account, Date.new(2026, 10, 2), 30)
    charge(account, Date.new(2026, 10, 3), -100)
    charge(account, Date.new(2026, 10, 20), 999) # after as_of
    # A balance update is a balance, not a charge or a credit
    account.entries.create!(name: "Balance update", date: Date.new(2026, 10, 1), amount: 360, currency: "USD", entryable: Valuation.new)

    summary = card.statement_summary(as_of: as_of)

    assert_equal 150, summary.charges.amount
    assert_equal(-100, summary.credits.amount)
    assert_equal 200, summary.remaining.amount
    assert_equal :partial, summary.status
    assert_equal Date.new(2026, 10, 5), summary.due_date
    assert_equal Date.new(2026, 10, 25), summary.next_close
  end

  test "the summary leaves charges and credits out when an entry is in another currency" do
    card = statement_card(close_day: 25, due_day: 5)
    create_balance(account: card.account, date: Date.new(2026, 9, 25), balance: 300)
    charge(card.account, Date.new(2026, 10, 1), 30)
    charge(card.account, Date.new(2026, 10, 2), 40, currency: "EUR")

    summary = card.statement_summary(as_of: Date.new(2026, 10, 16))

    assert_equal 300, summary.balance.amount
    assert_nil summary.charges
    assert_nil summary.credits
    assert_nil summary.remaining
    assert_nil summary.status
  end

  test "the summary marks a paid statement and moves to the next due date" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 300)
    charge(card.account, Date.new(2026, 10, 20), -300)

    summary = card.statement_summary(as_of: Date.new(2026, 10, 27))

    assert_equal :paid, summary.status
    assert_equal 0, summary.remaining.amount
    assert_equal Date.new(2026, 10, 26), summary.last_due_date
    assert_equal Date.new(2026, 11, 26), summary.due_date
  end

  test "the summary keeps an unpaid statement overdue" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: 300)

    summary = card.statement_summary(as_of: Date.new(2026, 10, 27))

    assert_equal :overdue, summary.status
    assert_equal Date.new(2026, 10, 26), summary.due_date
    assert_equal 300, summary.remaining.amount
  end

  test "the summary has no bill when the statement owes nothing" do
    card = statement_card(close_day: 10, due_day: 26)
    create_balance(account: card.account, date: Date.new(2026, 9, 20), balance: -20)

    summary = card.statement_summary(as_of: Date.new(2026, 10, 16))

    assert_equal :no_balance, summary.status
    assert_equal 0, summary.remaining.amount
  end

  test "the summary estimates the monthly interest on the remaining balance" do
    card = statement_card(close_day: 25, due_day: 5)
    card.update!(apr: 18)
    create_balance(account: card.account, date: Date.new(2026, 9, 1), balance: 1_000)

    summary = card.statement_summary(as_of: Date.new(2026, 10, 16))

    assert_equal 1.5, summary.monthly_rate
    assert_equal BigDecimal("15.00"), summary.estimated_interest.amount
  end

  test "the interest estimate keeps the currency's precision" do
    card = statement_card(close_day: 25, due_day: 5, currency: "KWD")
    card.update!(apr: 7)
    create_balance(account: card.account, date: Date.new(2026, 9, 1), balance: 123.457)

    summary = card.statement_summary(as_of: Date.new(2026, 10, 16))

    # 123.457 * 7% / 12 = 0.72016...
    assert_equal BigDecimal("0.720"), summary.estimated_interest.amount
  end

  test "no interest on a paid statement and no estimate without an APR" do
    card = statement_card(close_day: 25, due_day: 5)
    create_balance(account: card.account, date: Date.new(2026, 9, 1), balance: 0)

    assert_equal 0, card.statement_summary(as_of: Date.new(2026, 10, 16)).estimated_interest.amount

    card.update!(apr: nil)
    summary = card.statement_summary(as_of: Date.new(2026, 10, 16))
    assert_nil summary.estimated_interest
    assert_nil summary.monthly_rate
  end

  private
    # history: a zero balance long before the tests' dates, so the card's balance
    # history is known (a synced card)
    def statement_card(close_day:, due_day:, minimum_payment: 100, currency: "USD", history: true)
      card = CreditCard.create!(
        statement_close_day: close_day,
        due_day: due_day,
        minimum_payment: minimum_payment,
        apr: 18.99,
        available_credit: 5_000
      )

      families(:dylan_family).accounts.create!(
        name: "Statement Cycle Card",
        balance: 0,
        currency: currency,
        accountable: card
      )

      # Reloaded so the account's generated classification column is read back
      card.reload.account.reload
      create_balance(account: card.account, date: Date.new(2025, 1, 1), balance: 0) if history
      card
    end

    # A positive amount is a charge on a card; a negative one a payment or credit
    def charge(account, date, amount, currency: account.currency)
      account.entries.create!(
        name: "Statement test entry",
        date: date,
        amount: amount,
        currency: currency,
        entryable: Transaction.new
      )
    end
end
