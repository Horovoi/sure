class Rule::ConditionFilter::TransactionType < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    [
      [ "Income", "income" ],
      [ "Expense", "expense" ],
      [ "Transfer", "transfer" ]
    ]
  end

  def operators
    [ [ "Equal to", "=" ] ]
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
