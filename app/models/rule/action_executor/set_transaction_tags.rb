class Rule::ActionExecutor::SetTransactionTags < Rule::ActionExecutor
  # Several tags per action. The value is a list of tag ids (Rule::Action#execution_value);
  # a single id stored before multi-select keeps working.
  def type
    "multi_select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    tag_ids = (value.is_a?(String) ? value.split(",") : Array(value)).compact_blank
    selected_tag_ids = family.tags.where(id: tag_ids).pluck(:id)
    return 0 if selected_tag_ids.empty?

    scope = transaction_scope

    # A forced run (ignore_attribute_locks) may replace AI locks, never user locks
    scope = scope.enrichable(:tag_ids, force: ignore_attribute_locks)

    count_modified_resources(scope) do |txn|
      # The row lock closes the read-modify-write window: two rule runs on the
      # same transaction could otherwise read the same tags, and one write would
      # drop the other's tag.
      txn.with_lock do
        # Tags are additive: the selected tags join the ones users or other rules set
        existing_tag_ids = txn.tag_ids || []
        merged_tag_ids = (existing_tag_ids + selected_tag_ids).uniq

        txn.enrich_attribute(
          :tag_ids,
          merged_tag_ids,
          source: "rule",
          force: ignore_attribute_locks
        )
      end
    end
  end
end
