class Rule::ActionExecutor::SetTransactionMerchant < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.merchants.alphabetically.pluck(:name, :id)
  end

  def claimed_attributes
    [ :merchant_id ]
  end

  def actionable?(value)
    family.merchants.exists?(id: value)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    merchant = family.merchants.find_by_id(value)
    return 0 unless merchant

    scope = transaction_scope
    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks
    scope = scope.enrichable(:merchant_id, force: ignore_attribute_locks)

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :merchant_id,
        merchant.id,
        source: "rule",
        force: ignore_attribute_locks
      )
    end
  end
end
