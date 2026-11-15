class Rule::ConditionFilter::TransactionTag < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  # Tag membership is matched with a correlated EXISTS subquery, not a join. A
  # join would let two ANDed tag conditions collapse onto one `tags.id` alias
  # (`tags.id = a AND tags.id = b` is never true, even for a transaction with both
  # tags), and would return a transaction once per matching tagging, which
  # inflates counts and makes actions run on duplicates. EXISTS keeps each
  # condition independent and never multiplies rows.
  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    sanitize_operator(operator)

    case operator
    when "="
      scope.where(tagging_exists(tag_id: value))
    when "!="
      scope.where(Arel::Nodes::Not.new(tagging_exists(tag_id: value)))
    when "is_null"
      scope.where(Arel::Nodes::Not.new(tagging_exists))
    when "is_not_null"
      scope.where(tagging_exists)
    end
  end

  private
    # EXISTS over the transaction's taggings: of one tag when tag_id is given,
    # otherwise of any tag.
    def tagging_exists(tag_id: nil)
      taggings = Tagging
        .where(Tagging.arel_table[:taggable_id].eq(Transaction.arel_table[:id]))
        .where(taggable_type: "Transaction")
      taggings = taggings.where(tag_id: tag_id) if tag_id.present?
      taggings.arel.exists
    end
end
