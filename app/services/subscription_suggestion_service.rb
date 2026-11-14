class SubscriptionSuggestionService
  def initialize(family)
    @family = family
  end

  def detect
    # Creates or refreshes RecurringTransaction records from transaction
    # patterns, then marks likely subscriptions as suggestions
    RecurringTransaction::Identifier.new(@family).identify_recurring_patterns

    # Return count of open suggestions
    @family.recurring_transactions.suggested.count
  end
end
