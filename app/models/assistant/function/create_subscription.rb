# Creates a subscription, as Subscriptions > New does, or marks a transaction as one, as "Mark as subscription"
# in the transaction drawer does (RecurringTransaction.mark_from_transaction!). Idempotent by identity (merchant or
# name, currency, amount within 15%): a subscription that already has it is returned with created: false, and a
# detected row with it becomes the subscription instead of a second row appearing.
class Assistant::Function::CreateSubscription < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  scope_tag :write

  class << self
    def name
      "create_subscription"
    end

    def description
      <<~INSTRUCTIONS
        Adds a subscription (a bill that repeats monthly or yearly) to Subscriptions.

        Either pass transaction_id to make a subscription from one of its charges
        (amount, name, day and account come from that transaction), or pass name
        or merchant_id with amount, currency, billing_cycle and
        expected_day_of_month. A yearly cycle needs expected_month. With
        default_account_id, Sure books each due charge on that account.

        A subscription with the same merchant or name and currency (amount
        within 15%) is not added twice: it is returned with created: false. A
        detected suggestion with that identity becomes the subscription.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        transaction_id: { type: [ "string", "null" ], description: "Transaction id from get_transactions to make the subscription from" },
        name: { type: [ "string", "null" ], description: "Name, when there is no merchant (for example Netflix)" },
        merchant_id: { type: [ "string", "null" ], description: "Merchant id from get_merchants" },
        currency: { type: [ "string", "null" ], description: "ISO 4217 code. Defaults to the family currency" },
        **billing_properties
      }
    )
  end

  def record_type
    "RecurringTransaction"
  end

  def call(params = {})
    return create_from_transaction(params["transaction_id"]) if params["transaction_id"].present?

    merchant_id, error = resolve_merchant_id(params["merchant_id"])
    return error if error

    name = params["name"].to_s.squish.presence
    return tool_error("missing_name", "Pass name or merchant_id.") if merchant_id.nil? && name.nil?
    return tool_error("missing_amount", "Pass amount, the price of one billing period.") if params["amount"].nil?

    currency, error = resolve_currency(params["currency"])
    return error if error

    attributes, error = subscription_attributes(params)
    return error if error

    identity = { merchant_id: merchant_id, name: merchant_id ? nil : name, currency: currency }
    existing = RecurringTransaction.find_for_identity(family: family, amount: attributes[:amount], **identity)
    return result_for(existing, created: false) if existing&.subscription?

    # A new row gets the defaults of the New subscription form; a converted one keeps what detection found
    attributes = { billing_cycle: "monthly", expected_day_of_month: Date.current.day }.merge(attributes) unless existing
    billing_cycle = attributes[:billing_cycle] || existing&.billing_cycle
    if billing_cycle == "yearly" && (attributes[:expected_month] || existing&.expected_month).nil?
      return tool_error("missing_expected_month", "A yearly subscription needs expected_month (1-12).")
    end

    row = existing ? convert(existing, attributes) : create(identity.merge(attributes))
    result_for(row, created: existing.nil?, converted: existing.present?)
  rescue ActiveRecord::RecordNotUnique
    # A concurrent write (or a detected row with the exact amount) took the identity
    existing = RecurringTransaction.find_for_identity(family: family, amount: attributes[:amount], **identity)
    existing ? result_for(existing, created: false) : raise
  end

  private
    def create_from_transaction(transaction_id)
      transaction = valid_uuid?(transaction_id) ? family.transactions.find_by(id: transaction_id) : nil
      return tool_error("transaction_not_found", "Use a transaction id from get_transactions.") unless transaction

      result = RecurringTransaction.mark_from_transaction!(transaction, as: :subscription)
      result_for(result.recurring_transaction.reload, created: result.outcome == :created, converted: result.outcome == :converted)
    end

    # Like SubscriptionsController#create. The savepoint keeps a unique-index race from aborting a caller's
    # transaction.
    def create(attributes)
      row = family.recurring_transactions.new(attributes)
      row.subscription_state = "subscription"
      row.status = "active"
      row.last_occurrence_date ||= Date.current
      row.next_expected_date ||= row.first_expected_date
      RecurringTransaction.transaction(requires_new: true) { row.save! }
      row
    end

    # A detected pattern, suggestion or dismissed suggestion with this identity becomes the subscription, like
    # approving a suggestion
    def convert(row, attributes)
      RecurringTransaction.transaction(requires_new: true) do
        row.assign_attributes(attributes.compact)
        row.category_id = attributes[:category_id] || subscriptions_category_id || row.category_id
        row.default_account_id ||= row.inferred_account_id
        row.reactivate
        # Like approving a suggestion: no charge for a period nobody confirmed
        row.roll_next_expected_date_forward unless attributes[:next_expected_date]
        row.approve!
      end
      row
    end

    def subscriptions_category_id
      family.categories.find_by("LOWER(name) LIKE ?", "%subscription%")&.id
    end

    def result_for(row, created:, converted: false)
      { id: row.id, created: created, converted: converted.presence, subscription: subscription_snapshot(row) }.compact
    end
end
