class Rule::ActionExecutor::SetTransactionName < Rule::ActionExecutor
  def type
    "text"
  end

  def options
    nil
  end

  def claimed_attributes
    [ :name ]
  end

  def actionable?(value)
    value.present?
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    return 0 if value.blank?

    scope = transaction_scope.with_entry
    # Filter by entry's locked_attributes, not transaction's (name is on Entry).
    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks.
    scope = scope.where(Enrichable.unlocked_condition("entries", :name, force: ignore_attribute_locks))

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the entry was actually modified, false otherwise
      txn.entry.enrich_attribute(
        :name,
        value,
        source: "rule",
        force: ignore_attribute_locks
      )
    end
  end
end
