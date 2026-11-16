class CreditCard < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  # One read of the statement cycle for the Overview tab. All figures use the same
  # as_of date.
  StatementSummary = Data.define(
    :balance, :remaining, :charges, :credits, :accrued,
    :due_date, :last_due_date, :next_close, :status,
    :estimated_interest, :monthly_rate
  )

  validates :statement_close_day, :due_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true

  class << self
    def color
      "#F13636"
    end

    def icon
      "credit-card"
    end

    def classification
      "liability"
    end
  end

  def available_credit_money
    available_credit ? Money.new(available_credit, account.currency) : nil
  end

  def minimum_payment_money
    minimum_payment ? Money.new(minimum_payment, account.currency) : nil
  end

  def annual_fee_money
    annual_fee ? Money.new(annual_fee, account.currency) : nil
  end

  # -- Statement cycle ---------------------------------------------------------
  #
  # A statement closes on statement_close_day every month. A day the month does not
  # have (31 in a 30-day month, 29-31 in February) moves to the month's last day.
  # The close day itself belongs to the statement that closes on it.

  def statement_cycle_configured?
    statement_close_day.present? && account.present?
  end

  # The last close on or before as_of
  def last_statement_close_date(as_of: Date.current)
    return nil unless statement_cycle_configured?

    close = day_of_month_in(as_of, statement_close_day)
    return close if close <= as_of

    day_of_month_in(as_of.prev_month, statement_close_day)
  end

  def previous_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.prev_month, statement_close_day)
  end

  def next_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.next_month, statement_close_day)
  end

  # The due date of the statement that closes on close_date. A due day before the
  # close day falls in the next month. The configured days decide this, not the
  # clamped dates: a 31/28 card is due on 28 March for the statement of 28 February.
  def payment_due_date_for(close_date)
    return nil if close_date.nil? || due_day.blank?

    if statement_close_day.present? && due_day < statement_close_day
      day_of_month_in(close_date.next_month, due_day)
    else
      day_of_month_in(close_date, due_day)
    end
  end

  # The due date the cardholder has to meet next. The closed statement keeps its due
  # date until it is paid, so an unpaid bill reads as overdue.
  def next_payment_due_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    due = payment_due_date_for(last_close)
    return nil if due.nil?

    if due < as_of && statement_settled?(as_of: as_of)
      payment_due_date_for(next_statement_close_date(as_of: as_of))
    else
      due
    end
  end

  def days_until_due(as_of: Date.current)
    due = next_payment_due_date(as_of: as_of)
    return nil if due.nil?

    (due - as_of).to_i
  end

  # What the card owed at the last close. It comes from the materialized balances,
  # so opening balances, balance updates and other-currency entries count the same
  # way as in the account balance.
  def last_statement_balance_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    balance_on(last_close)
  end

  # The change in the debt since the last close. With the statement balance it adds
  # up to the balance on as_of. Negative when payments since the close are larger
  # than the charges: a credit toward the next statement.
  def accrued_since_last_close_money(as_of: Date.current)
    statement = last_statement_balance_money(as_of: as_of)
    current = balance_on(as_of) if statement
    return nil if statement.nil? || current.nil?

    current - statement
  end

  def statement_summary(as_of: Date.current)
    return nil unless statement_cycle_configured?

    last_close = last_statement_close_date(as_of: as_of)
    balance = last_statement_balance_money(as_of: as_of)
    totals = cycle_totals((last_close + 1)..as_of)
    credits = totals&.fetch(:credits)
    remaining = statement_remaining(balance, credits)
    last_due_date = payment_due_date_for(last_close)

    StatementSummary.new(
      balance: balance,
      remaining: remaining,
      charges: totals&.fetch(:charges),
      credits: credits,
      accrued: accrued_since_last_close_money(as_of: as_of),
      due_date: statement_due_date(last_due_date, remaining, as_of),
      last_due_date: last_due_date,
      next_close: next_statement_close_date(as_of: as_of),
      status: statement_status(balance: balance, remaining: remaining, due_date: last_due_date, as_of: as_of),
      estimated_interest: estimated_monthly_interest_money(remaining),
      monthly_rate: monthly_rate
    )
  end

  # The minimum payment only means something against the statement it is part of
  def minimum_payment_shortfall?(as_of: Date.current)
    minimum = minimum_payment_money
    balance = last_statement_balance_money(as_of: as_of)
    return false if minimum.nil? || balance.nil?

    balance > minimum
  end

  private
    # The end-of-day balance on date: the last materialized balance on or before it.
    # Zero before the card's history starts; unknown (nil) when the card has no
    # balances yet (it was not synced).
    def balance_on(date)
      balances = account.balances.where(currency: account.currency)
      amount = balances.where(date: ..date).order(date: :desc).pick(:end_balance)
      return Money.new(amount, account.currency) unless amount.nil?

      balances.exists? ? Money.new(0, account.currency) : nil
    end

    # Charges (positive) and payments or credits (negative) booked in window.
    # Transactions only: a valuation is a balance, not a flow. Nil when an entry is
    # in another currency (or none): a total of only part of the entries would read
    # as the whole.
    def cycle_totals(window)
      # A split transaction counts once, as the bank booked it (its parent)
      scoped = account.entries.excluding_pending.excluding_split_children.where(entryable_type: "Transaction", date: window)
      summable = scoped.where(currency: account.currency)
      return nil if summable.count != scoped.count

      charges, credits = summable.pick(
        Arel.sql("COALESCE(SUM(CASE WHEN entries.amount > 0 THEN entries.amount ELSE 0 END), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN entries.amount < 0 THEN entries.amount ELSE 0 END), 0)")
      )

      { charges: Money.new(charges, account.currency), credits: Money.new(credits, account.currency) }
    end

    # Paid when the payments since the close cover the statement balance
    def statement_settled?(as_of:)
      balance = last_statement_balance_money(as_of: as_of)
      return false if balance.nil?
      return true unless balance.positive?

      credits = cycle_totals((last_statement_close_date(as_of: as_of) + 1)..as_of)&.fetch(:credits)
      return false if credits.nil?

      credits.amount.abs >= balance.amount
    end

    def statement_remaining(balance, credits)
      return nil if balance.nil? || credits.nil?
      return Money.new(0, balance.currency) unless balance.positive?

      Money.new([ balance.amount + credits.amount, 0 ].max, balance.currency)
    end

    # A settled statement whose due date has passed gives way to the next one. An
    # unpaid one keeps its date, so the Overview says it is overdue.
    def statement_due_date(last_due_date, remaining, as_of)
      return last_due_date if last_due_date.nil? || remaining.nil?
      return last_due_date unless remaining.zero? && last_due_date < as_of

      payment_due_date_for(next_statement_close_date(as_of: as_of))
    end

    def statement_status(balance:, remaining:, due_date:, as_of:)
      return nil if balance.nil? || remaining.nil?
      return :no_balance unless balance.positive?
      return :paid if remaining.zero?
      return :overdue if due_date.present? && due_date < as_of
      return :partial if remaining.amount < balance.amount

      :unpaid
    end

    def monthly_rate
      apr / 12 if apr.present?
    end

    # Rounded to the currency's precision, so a three-decimal currency keeps its
    # third decimal
    def estimated_monthly_interest_money(balance)
      return nil if apr.blank? || balance.nil?
      return Money.new(0, account.currency) unless balance.positive?

      Money.new(
        (balance.amount * apr / 100 / 12).round(balance.currency.default_precision || 2),
        account.currency
      )
    end

    def day_of_month_in(base_date, day)
      Date.new(base_date.year, base_date.month, [ day, base_date.end_of_month.day ].min)
    end
end
