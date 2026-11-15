# Skips one billing period of a subscription without booking a charge, as Skip on Subscriptions does
# (RecurringTransaction#skip_occurrence!): the next billing date moves one period on.
class Assistant::Function::SkipSubscriptionOccurrence < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  scope_tag :write

  class << self
    def name
      "skip_subscription_occurrence"
    end

    def description
      <<~INSTRUCTIONS
        Skips the next charge of a subscription (for example a month that was
        not billed): its next billing date moves one billing period on and no
        transaction is booked. Each call skips one more period.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Subscription id from get_subscriptions" }
      }
    )
  end

  def record_type
    "RecurringTransaction"
  end

  def audit_before(params)
    row = find_recurring_row(params["id"], scope: recurring_rows.subscriptions)
    row && subscription_snapshot(row)
  end

  def call(params = {})
    row = find_recurring_row(params["id"], scope: recurring_rows.subscriptions)
    return tool_error("not_found", "Use the id of a subscription from get_subscriptions (filter active or paused).") unless row

    skipped = row.skip_occurrence!

    { id: row.id, skipped_date: skipped&.iso8601, next_expected_date: row.next_expected_date.iso8601, subscription: subscription_snapshot(row) }.compact
  end
end
