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
    transfer_kinds = Transaction::TRANSFER_KINDS.map { |kind| ActiveRecord::Base.connection.quote(kind) }.join(", ")
    transfer_condition = "transactions.kind IN (#{transfer_kinds})"
    investment_contribution_condition = "transactions.kind = 'investment_contribution'"

    case value
    when "income"
      scope.where("entries.amount < 0 AND NOT (#{transfer_condition})")
    when "expense"
      scope.where("(entries.amount >= 0 OR #{investment_contribution_condition}) AND NOT (#{transfer_condition})")
    when "transfer"
      scope.where(Arel.sql(transfer_condition))
    else
      scope
    end
  end
end
