class Rule::ActionExecutor::ExcludeTransaction < Rule::ActionExecutor
  def label
    "Exclude from budgeting and reports"
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    scope = transaction_scope.with_entry

    # Filter by entry's locked_attributes, not transaction's (excluded is on Entry).
    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks.
    scope = scope.where(Enrichable.unlocked_condition("entries", :excluded, force: ignore_attribute_locks))

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the entry was actually modified, false otherwise
      txn.entry.enrich_attribute(
        :excluded,
        true,
        source: "rule",
        force: ignore_attribute_locks
      )
    end
  end
end
