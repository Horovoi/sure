module CreditCardsHelper
  # 1st .. 31st for the statement close day and the due day
  def credit_card_day_of_month_options
    (1..31).map { |day| [ day.ordinalize, day ] }
  end

  # "Due in 3 days", "Due today", "2 days overdue"
  def credit_card_due_countdown(days)
    return nil if days.nil?
    return t("credit_cards.due.overdue", count: days.abs) if days.negative?

    t("credit_cards.due.in_days", count: days)
  end
end
