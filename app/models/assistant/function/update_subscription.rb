# Changes a subscription or other recurring bill, as the Edit subscription form does, and pauses or resumes it, as
# the pause toggle on Subscriptions does (mark_inactive! / mark_active!). Nothing is deleted here.
class Assistant::Function::UpdateSubscription < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  STATUSES = %w[active paused].freeze

  scope_tag :write

  class << self
    def name
      "update_subscription"
    end

    def description
      <<~INSTRUCTIONS
        Changes a subscription or other recurring bill: its name, amount, billing
        cycle and day, next billing date, paying account, category or notes, or
        pauses and resumes it (status paused or active). Find the id with
        get_subscriptions; pass only the fields to change.

        A changed billing day moves the next billing date to that day unless
        next_expected_date is passed too. A paused row books no charges; a
        resumed one starts again from its next future billing date.
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
        id: { type: "string", description: "Subscription id from get_subscriptions" },
        name: { type: "string", description: "New name (a row with a merchant shows the merchant's name)" },
        status: { type: "string", enum: STATUSES, description: "paused stops it, active resumes it" },
        **billing_properties
      }
    )
  end

  def record_type
    "RecurringTransaction"
  end

  def idempotent?
    true
  end

  def audit_before(params)
    row = find_recurring_row(params["id"], scope: recurring_rows.user_managed)
    row && subscription_snapshot(row)
  end

  def call(params = {})
    row = find_recurring_row(params["id"], scope: recurring_rows.user_managed)
    return not_found_or_unmanaged(params["id"]) unless row

    status = params["status"].presence
    return tool_error("invalid_status", "status must be active or paused.") if status && !STATUSES.include?(status)

    attributes, error = subscription_attributes(params)
    return error if error
    return tool_error("no_changes", "Pass at least one field to change.") if attributes.empty? && status.nil?

    billing_day_changed = attributes.key?(:expected_day_of_month) && attributes[:expected_day_of_month] != row.expected_day_of_month

    RecurringTransaction.transaction do
      row.update!(attributes) if attributes.any?

      if billing_day_changed && !attributes.key?(:next_expected_date)
        row.update!(next_expected_date: row.first_expected_date)
      end

      if status == "paused" && row.active?
        row.mark_inactive!
      elsif status == "active" && row.inactive?
        row.mark_active!
      end
    end

    { id: row.id, updated: true, subscription: subscription_snapshot(row.reload) }
  end

  private
    # A detected pattern or suggestion is reviewed with review_subscription_suggestion, not edited
    def not_found_or_unmanaged(id)
      return not_found_error unless find_recurring_row(id)

      tool_error("not_editable", "This row is a detected suggestion or pattern. Approve it with review_subscription_suggestion first.")
    end
end
