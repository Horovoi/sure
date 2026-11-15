class Rule::ConditionFilter::TransactionDetails < Rule::ConditionFilter
  def type
    "text"
  end

  # The JSONB search only has contains, equals and empty semantics, so this filter
  # keeps the original operators instead of the extended text set.
  def operators
    [
      [ operator_label(:contains), "like" ],
      [ operator_label(:equal_to), "=" ],
      [ operator_label(:is_empty), "is_null" ]
    ]
  end

  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    # Search within the transaction's extra JSONB field (details an import or the
    # app stored on the transaction, such as a payee, a memo or an exchange rate)

    # Validate operator using parent class method
    sanitize_operator(operator)

    if operator == "is_null"
      # Check if extra field is empty or null
      scope.where("transactions.extra IS NULL OR transactions.extra = '{}'::jsonb")
    else
      # For both "like" and "=" operators, perform contains search
      # "like" is case-insensitive (ILIKE), "=" is case-sensitive (LIKE)
      # Note: For JSONB fields, both operators use contains semantics rather than exact match
      # because searching within structured JSON data makes contains more useful than exact equality
      #
      # Only the string and number values are searched, at any depth. Casting the
      # whole document to text also searched its keys and its true/false/null
      # literals, so "rate" matched every transaction with an exchange_rate key.
      sanitized_value = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      sql_operator = operator == "like" ? "ILIKE" : "LIKE"

      scope.where(<<~SQL.squish, sanitized_value)
        EXISTS (
          SELECT 1 FROM jsonb_path_query(transactions.extra, 'strict $.**') AS node
          WHERE jsonb_typeof(node) IN ('string', 'number')
            AND node #>> '{}' #{sql_operator} ?
        )
      SQL
    end
  end
end
