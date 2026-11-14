class Rule::ActionExecutor::SetInvestmentActivityLabel < Rule::ActionExecutor
  def label
    "Set investment activity label"
  end

  def type
    "select"
  end

  def options
    Transaction::ACTIVITY_LABELS.map { |l| [ l, l ] }
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    return 0 unless Transaction::ACTIVITY_LABELS.include?(value)

    scope = transaction_scope

    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks
    scope = scope.enrichable(:investment_activity_label, force: ignore_attribute_locks)

    count_modified_resources(scope) do |txn|
      txn.enrich_attribute(
        :investment_activity_label,
        value,
        source: "rule",
        force: ignore_attribute_locks
      )
    end
  end
end
