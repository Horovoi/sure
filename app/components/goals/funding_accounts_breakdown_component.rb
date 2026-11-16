class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  COLUMN_WINDOW_DAYS = 30
  TREND_WINDOW_DAYS = 90

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def rows
    @rows ||= goal.linked_accounts.sort_by { |a| -goal.account_backing(a).amount.to_d }.map do |account|
      totals = inflow_totals_for(account)
      backing = goal.account_backing(account).amount.to_d
      native = goal.account_native_backing(account)
      goal_account = goal_account_by_id[account.id]
      {
        account: account,
        backing: backing,
        backing_money: Money.new(backing, goal.currency),
        balance_money: Money.new(account.balance.to_d, account.currency),
        native_backing_money: native,
        converted: account.currency != goal.currency,
        # Zero converts without a rate, so only a nonzero share can be left out.
        rate_missing: !native.zero? && goal.missing_exchange_rate_currencies.include?(account.currency),
        earmarked: goal_account&.allocated_amount.present?,
        last_30_money: Money.new(totals[:last_30], goal.currency),
        last_90_money: Money.new(totals[:last_90], goal.currency)
      }
    end
  end

  def total
    @total ||= rows.sum { |r| r[:backing].to_d }
  end

  def percent_for(backing)
    return 0 if total.zero?
    ((backing.to_d / total) * 100).round
  end

  # Goal#account_color: the bar segments and row avatars match the card's
  # account stack and the form
  def color_for(account)
    goal.account_color(account)
  end

  def accountable_label(account)
    helpers.goal_account_kind_label(account)
  end

  private
    def goal_account_by_id
      @goal_account_by_id ||= goal.goal_accounts.index_by(&:account_id)
    end

    def inflow_totals_for(account)
      inflow_totals_map[account.id] || { last_30: 0.to_d, last_90: 0.to_d }
    end

    # Per-account net inflow for both windows in one pass over the 90-day
    # entries set. Entry amount sign in Sure: inflow is negative; flip and
    # clamp ≥ 0. Converted at today's rate, like Goal#pace.
    def inflow_totals_map
      @inflow_totals_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        cutoff_30 = COLUMN_WINDOW_DAYS.days.ago.to_date

        rows = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account_ids, date: TREND_WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .merge(Transaction.excluding_pending)
          .pluck(:account_id, :date, :amount, :currency)

        result = Hash.new { |h, k| h[k] = { last_30: 0.to_d, last_90: 0.to_d } }
        accounts_by_id = goal.linked_accounts.index_by(&:id)
        rows.each do |aid, date, amount, currency|
          inflow = goal.convert_money(Money.new((-amount.to_d).clamp(0..), currency.presence || accounts_by_id.fetch(aid).currency)).amount
          result[aid][:last_90] += inflow
          result[aid][:last_30] += inflow if date >= cutoff_30
        end
        result
      end
    rescue StandardError => e
      Rails.logger.error("Inflow totals map for goal #{goal.id} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end
end
