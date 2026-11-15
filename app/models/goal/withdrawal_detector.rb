# Finds money that left a goal's accounts without anything saying where it went
# (w2-goals goal-spending, ported from upstream).
#
# A goal reads balances, not transactions, so an outflow reaches it only as a smaller
# number. Goal#consume! records a spend, but only when the user thinks to. This lists
# the outflows nothing has claimed, so the goal page can ask.
#
# Fork rules on top of upstream:
# - Transfer kinds (funds_movement, cc_payment, loan_payment) and investment
#   contributions move money between the family's own accounts. They are not spending,
#   so they are never offered. Moving savings to the card is not the trip: the spend
#   on the card is.
# - The window is fiscal: the current budget month and the two before it, in the
#   family's time zone, so it moves with the family's month start.
# - The threshold is in USD-equivalent units, converted to each account's currency by
#   the nearest-rate rule, so a UAH account is not asked about every coffee.
class Goal::WithdrawalDetector
  # Below this an attribution is more friction than it is worth
  MIN_AMOUNT = Money.new(100, "USD")

  # Budget months to look back over, the current one included
  LOOKBACK_FISCAL_MONTHS = 3

  NOT_SPENDING_KINDS = (Transaction::TRANSFER_KINDS + %w[investment_contribution]).freeze

  def initialize(goal, accounts: nil, today: nil)
    @goal = goal
    @accounts = accounts
    @today = today
  end

  # Unclaimed outflows on the goal's accounts, newest first. Empty for a reserve (drawn
  # down and refilled, not spent) and for a goal that is not active (a released goal
  # has handed its accounts back; consume! refuses it too).
  def unattributed_outflows(limit: 3)
    return Entry.none unless goal.one_off? && goal.active?
    return Entry.none if accounts.empty?

    candidates.limit(limit)
  end

  # First day of the window: the start of the budget month LOOKBACK_FISCAL_MONTHS - 1
  # months before the current one
  def window_start
    start = family.budget_period_start_for(today)
    (LOOKBACK_FISCAL_MONTHS - 1).times { start = family.budget_period_start_for(start - 1.day) }
    start
  end

  private
    attr_reader :goal

    def family
      goal.family
    end

    def accounts
      @accounts ||= goal.linked_accounts.to_a
    end

    # Requests run in the family's zone; a job or console may not
    def today
      @today ||= Time.current.in_time_zone(family.resolved_time_zone).to_date
    end

    def candidates
      Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: accounts.map(&:id))
        .where(excluded: false)
        .where(date: window_start..today)
        .where(threshold_condition)
        .where("transactions.extra -> 'goal' ->> 'consumed_goal_id' IS NULL")
        .where("transactions.extra -> 'goal' ->> 'pledge_id' IS NULL")
        # Transfer is the only writer of a leg's kind, so the kind is enough here
        .where.not(transactions: { kind: NOT_SPENDING_KINDS })
        # A pending charge can still be reversed or replaced by its posted form
        .merge(Transaction.excluding_pending)
        .order(date: :desc, id: :desc)
    end

    # In Sure an outflow is the positive side. One condition per account, each with the
    # threshold in that account's currency.
    def threshold_condition
      table = Entry.arel_table
      accounts.map do |account|
        table[:account_id].eq(account.id).and(table[:amount].gteq(threshold_in(account.currency)))
      end.reduce(:or)
    end

    def threshold_in(currency)
      goal.convert_money!(MIN_AMOUNT, to: currency).amount
    rescue Money::ConversionError
      # No rate: the plain figure, so the panel still works
      MIN_AMOUNT.amount
    end
end
