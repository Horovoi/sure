# Books the due charge of a subscription on its paying account, as Record on Subscriptions does
# (RecurringTransaction#record_charge!). The audit names the booked entry, so a wrong charge can be deleted, and
# keeps the subscription's state before (its next billing date).
class Assistant::Function::RecordSubscriptionCharge < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  ERRORS = {
    no_account: "The subscription has no paying account. Set default_account_id with update_subscription first.",
    not_due: "The subscription is not due yet (due: false in get_subscriptions). Sure books the charge on its billing date.",
    no_exchange_rate: "No exchange rate converts the subscription currency into the account currency yet. Try again after the next rate sync.",
    already_exists: "A charge for this billing period is already booked."
  }.freeze

  scope_tag :write

  class << self
    def name
      "record_subscription_charge"
    end

    def description
      <<~INSTRUCTIONS
        Books the charge of a subscription that is due today or overdue (due:
        true in get_subscriptions) as a transaction on its paying account, in
        that account's currency, and moves the next billing date one period on.
        Each call books one billing period, and a period is never booked twice:
        when several periods are overdue, call it once per period.
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
    "Entry"
  end

  def audit_before(params)
    row = find_recurring_row(params["id"], scope: recurring_rows.subscriptions)
    row && subscription_snapshot(row)
  end

  # The booked entry; the subscription itself is in audit_before
  def audit_refs(result)
    return [] unless result.is_a?(Hash)

    [ result[:entry_id] ].compact.map(&:to_s)
  end

  def call(params = {})
    row = find_recurring_row(params["id"], scope: recurring_rows.subscriptions)
    return tool_error("not_found", "Use the id of a subscription from get_subscriptions.") unless row

    result = row.record_charge!
    return tool_error(result.error.to_s, ERRORS.fetch(result.error), subscription_id: row.id) unless result.recorded?

    entry = result.entry
    {
      subscription_id: row.id,
      entry_id: entry.id,
      transaction_id: entry.entryable_id,
      date: entry.date.iso8601,
      amount: entry.amount.to_f,
      currency: entry.currency,
      account: { id: entry.account_id, name: entry.account.name },
      subscription: subscription_snapshot(row.reload)
    }
  end
end
