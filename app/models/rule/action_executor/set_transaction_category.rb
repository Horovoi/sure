class Rule::ActionExecutor::SetTransactionCategory < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.categories.alphabetically.pluck(:name, :id)
  end

  def claimed_attributes
    [ :category_id ]
  end

  def actionable?(value)
    family.categories.exists?(id: value)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    category = family.categories.find_by_id(value)
    return 0 unless category

    scope = transaction_scope

    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks
    scope = scope.enrichable(:category_id, force: ignore_attribute_locks)

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :category_id,
        category.id,
        source: "rule",
        force: ignore_attribute_locks
      )
    end
  end
end
