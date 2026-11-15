# Reviews a detected subscription, as Subscriptions > Suggestions does: approve it (it becomes a subscription that
# starts from its next future billing date), dismiss it, or restore a dismissed one to the suggestions. The
# AASM events of RecurringTransaction decide which moves are allowed.
class Assistant::Function::ReviewSubscriptionSuggestion < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  DECISIONS = %w[approve dismiss restore].freeze
  # The state each decision starts from
  FROM_STATES = { "approve" => %w[suggested dismissed], "dismiss" => %w[suggested], "restore" => %w[dismissed] }.freeze

  scope_tag :write

  class << self
    def name
      "review_subscription_suggestion"
    end

    def description
      <<~INSTRUCTIONS
        Approves, dismisses or restores a detected subscription (get_subscriptions
        with filter suggested or dismissed lists them).

        - approve: it becomes a subscription, in the Subscriptions category when
          there is one, paid from the account its charges came from, starting
          at its next future billing date. With use_base_currency, a suggestion
          detected in a foreign currency but paid in the family currency is
          kept in that base currency (see detected_base).
        - dismiss: it leaves the suggestions and is not suggested again.
        - restore: a dismissed one goes back to the suggestions.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[id decision],
      properties: {
        id: { type: "string", description: "Row id from get_subscriptions" },
        decision: { type: "string", enum: DECISIONS, description: "approve, dismiss or restore" },
        use_base_currency: { type: "boolean", description: "approve only: keep the detected base currency and amount" }
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
    row = find_recurring_row(params["id"])
    row && subscription_snapshot(row)
  end

  def call(params = {})
    decision = params["decision"].to_s
    return tool_error("invalid_decision", "decision must be approve, dismiss or restore.") unless DECISIONS.include?(decision)

    row = find_recurring_row(params["id"])
    return not_found_error unless row

    state = row.subscription_state
    unless FROM_STATES.fetch(decision).include?(state)
      return tool_error(
        "invalid_transition",
        "This row is #{subscription_kind(row)}; #{decision} works only on #{FROM_STATES.fetch(decision).join(" or ")} rows.",
        kind: subscription_kind(row)
      )
    end

    case decision
    when "approve" then row.approve_suggestion!(use_base_currency: ActiveModel::Type::Boolean.new.cast(params["use_base_currency"]) == true)
    when "dismiss" then row.dismiss_suggestion!
    when "restore" then row.restore_suggestion!
    end

    { id: row.id, decision: decision, subscription: subscription_snapshot(row.reload) }
  rescue AASM::InvalidTransition
    tool_error("invalid_transition", "The row changed meanwhile; read it again with get_subscriptions.")
  end
end
