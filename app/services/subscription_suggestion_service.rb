class SubscriptionSuggestionService
  def initialize(family)
    @family = family
  end

  def detect
    # Stage 1: Create RecurringTransaction records from transaction patterns
    RecurringTransaction::Identifier.new(@family).identify_recurring_patterns

    # Stage 2: Mark likely subscriptions as suggestions
    RecurringTransaction::SubscriptionDetector.detect_for_family(@family)

    # Auto-approve any that were manually marked as subscriptions
    RecurringTransaction::SubscriptionDetector.auto_approve_for_family(@family)

    # Return count of new suggestions
    @family.recurring_transactions.suggested.count
  end
end
