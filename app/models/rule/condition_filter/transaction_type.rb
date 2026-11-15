class Rule::ConditionFilter::TransactionType < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    [
      [ I18n.t("rules.condition_filters.transaction_type.income"), "income" ],
      [ I18n.t("rules.condition_filters.transaction_type.expense"), "expense" ],
      [ I18n.t("rules.condition_filters.transaction_type.transfer"), "transfer" ]
    ]
  end

  def operators
    [ [ operator_label(:equal_to), "=" ] ]
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    transfer, expense, investment_contribution = Transaction.type_conditions.values_at(:transfer, :expense, :investment_contribution)

    case value
    when "income"
      # An investment contribution is an expense whatever its sign, so it is never income
      scope.where(Entry.arel_table[:amount].lt(0).and(investment_contribution.not).and(transfer.not))
    when "expense"
      scope.where(expense.and(transfer.not))
    when "transfer"
      scope.where(transfer)
    else
      scope
    end
  end
end
