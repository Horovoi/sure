module GoalsHelper
  # Completing a goal releases its money, so both places that offer it (the header menu
  # and the celebration panel) ask first, with the same question
  def goal_complete_confirm(goal)
    body = if goal.progress_percent < 100
      t("goals.show.confirm_complete_body_short",
        progress: goal.progress_percent,
        saved: goal.current_balance_money.format(precision: 0),
        target: goal.target_amount_money.format(precision: 0))
    else
      t("goals.show.confirm_complete_body")
    end

    CustomConfirm.new(
      title: t("goals.show.confirm_complete_title"),
      body: body,
      btn_text: t("goals.show.confirm_complete_cta")
    )
  end

  # Fixed earmarks on `account` held by goals other than the one being edited, from the
  # pooled map loaded once per render (the form lists every fundable account). Leaving
  # the current goal out keeps its own earmark from reading as somebody else's.
  # Whole-balance links count zero here; GoalAccount refuses a second one at write time.
  def earmarked_by_other_goals(account, pooled:, current_goal: nil)
    other_goal_rows(account, pooled, current_goal).sum { |row| row[:allocated_amount].to_d }
  end

  # Whether another live goal claims `account` in full, which the sum above cannot tell
  def whole_account_claimed_by_other_goals?(account, pooled:, current_goal: nil)
    other_goal_rows(account, pooled, current_goal).any? { |row| row[:allocated_amount].nil? }
  end

  # An account in another currency than the goal names its currency
  def goal_account_label(account, goal)
    account.currency == goal.currency ? account.name : "#{account.name} · #{account.currency}"
  end

  # Today's account-to-goal rate for the earmark hint, nil when the currencies match or
  # no rate exists
  def earmark_conversion_rate(goal, account, currency)
    return if account.currency == currency

    goal.convert_money(Money.new(1, account.currency), to: currency).amount.nonzero?
  end

  private
    def other_goal_rows(account, pooled, current_goal)
      (pooled[account.id] || []).reject { |row| current_goal&.persisted? && row[:goal_id] == current_goal.id }
    end
end
