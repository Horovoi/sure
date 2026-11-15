# Shared by the subscription tools: finding a recurring row of the family, the shape every tool returns (and the
# audit keeps as the state before a write), and amounts in the family currency.
#
# A recurring row is one of these kinds, which the tools name the way the Subscriptions page does:
# - subscription: a confirmed subscription (active, or paused by the user);
# - suggested / dismissed: a detected subscription waiting for review, or one the user dismissed;
# - other_recurring: a manual recurring row that is not a subscription (Subscriptions > Other recurring);
# - pattern: a detected recurring pattern, not shown anywhere as a subscription.
module Assistant::Function::SubscriptionsSupport
  BILLING_CYCLES = %w[monthly yearly].freeze

  private
    def recurring_rows
      family.recurring_transactions
    end

    def find_recurring_row(id, scope: recurring_rows)
      valid_uuid?(id) ? scope.includes(:merchant, :category, :default_account, :subscription_service).find_by(id: id) : nil
    end

    def not_found_error
      tool_error("not_found", "Use a subscription id from get_subscriptions (filter all lists every reviewable row).")
    end

    def subscription_kind(row)
      return row.subscription_state unless row.pattern?

      row.manual? ? "other_recurring" : "pattern"
    end

    def subscription_snapshot(row)
      monthly = in_family_currency(row.billing_cycle_yearly? ? row.amount_money / 12 : row.amount_money)

      {
        id: row.id,
        name: row.display_name,
        kind: subscription_kind(row),
        status: row.active? ? "active" : "paused",
        inactive_reason: row.inactive_reason,
        amount: row.amount.to_f,
        currency: row.currency,
        billing_cycle: row.billing_cycle,
        expected_day_of_month: row.expected_day_of_month,
        expected_month: row.expected_month,
        next_expected_date: row.next_expected_date&.iso8601,
        last_occurrence_date: row.last_occurrence_date&.iso8601,
        due: row.actionable?,
        monthly_cost_in_family_currency: monthly&.amount&.to_f,
        merchant: row.merchant && { id: row.merchant.id, name: row.merchant.name },
        category: row.category && { id: row.category.id, name: row.category.name },
        default_account: row.default_account && { id: row.default_account.id, name: row.default_account.name },
        service: row.subscription_service&.name,
        notes: row.notes.presence,
        detected_base: detected_base(row)
      }.compact
    end

    # A suggestion detected in a foreign currency that the family pays in its own currency
    def detected_base(row)
      return unless row.detected_base_currency.present? && row.detected_base_amount.present?

      { amount: row.detected_base_amount.to_f, currency: row.detected_base_currency }
    end

    # nil when no rate converts the currency at all: such an amount is left out of a total, never counted at 1
    def in_family_currency(money)
      ExchangeRate.convert_or_leave_out(money, to: family.currency, source: "Assistant subscription tools", family: family)
    end

    # Returns [value, error]: nil clears, a visible account of the family sets, anything else is an error
    def resolve_default_account_id(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if valid_uuid?(value) && family.accounts.visible.exists?(id: value)

      [ nil, tool_error("invalid_account", "default_account_id must be an account id from get_accounts, or null to clear it.") ]
    end

    def resolve_category_id(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if valid_uuid?(value) && family.categories.exists?(id: value)

      [ nil, tool_error("invalid_category", "category_id must be an id from get_categories, or null to clear it.") ]
    end

    def resolve_merchant_id(value)
      return [ nil, nil ] if value.blank?
      return [ value, nil ] if valid_uuid?(value) && family.available_merchants.exists?(id: value)

      [ nil, tool_error("invalid_merchant", "merchant_id must be an id from get_merchants, or null.") ]
    end

    def resolve_currency(value)
      code = value.to_s.strip.upcase.presence || family.currency
      [ Money::Currency.new(code).iso_code, nil ]
    rescue Money::Currency::UnknownCurrencyError
      [ nil, tool_error("invalid_currency", "currency must be an ISO 4217 code such as UAH or USD.") ]
    end

    def resolve_date(value, field)
      return [ nil, nil ] if value.blank?

      [ Date.iso8601(value.to_s), nil ]
    rescue Date::Error
      [ nil, tool_error("invalid_#{field}", "#{field} must be a date (YYYY-MM-DD).") ]
    end

    # The billing fields that create_subscription and update_subscription share, as model attributes. Returns
    # [attributes, error]; only the keys present in params are set.
    def subscription_attributes(params)
      attributes = {}

      if params.key?("name") && params["name"].present?
        attributes[:name] = params["name"].to_s.squish
      end

      if params.key?("amount") && !params["amount"].nil?
        amount = BigDecimal(params["amount"].to_s)
        return [ nil, tool_error("invalid_amount", "amount must be a positive number, the price of one billing period.") ] unless amount.positive?

        attributes[:amount] = amount
      end

      if params["billing_cycle"].present?
        return [ nil, tool_error("invalid_billing_cycle", "billing_cycle must be monthly or yearly.") ] unless BILLING_CYCLES.include?(params["billing_cycle"])

        attributes[:billing_cycle] = params["billing_cycle"]
      end

      if params.key?("expected_day_of_month") && !params["expected_day_of_month"].nil?
        day = params["expected_day_of_month"].to_i
        return [ nil, tool_error("invalid_expected_day_of_month", "expected_day_of_month must be 1 to 31.") ] unless day.between?(1, 31)

        attributes[:expected_day_of_month] = day
      end

      if params.key?("expected_month") && !params["expected_month"].nil?
        month = params["expected_month"].to_i
        return [ nil, tool_error("invalid_expected_month", "expected_month must be 1 to 12.") ] unless month.between?(1, 12)

        attributes[:expected_month] = month
      end

      if params.key?("next_expected_date")
        date, error = resolve_date(params["next_expected_date"], "next_expected_date")
        return [ nil, error ] if error

        attributes[:next_expected_date] = date if date
      end

      { "default_account_id" => :resolve_default_account_id, "category_id" => :resolve_category_id }.each do |key, resolver|
        next unless params.key?(key)

        value, error = send(resolver, params[key])
        return [ nil, error ] if error

        attributes[key.to_sym] = value
      end

      attributes[:notes] = params["notes"].to_s.strip.presence if params.key?("notes")

      [ attributes, nil ]
    rescue ArgumentError, TypeError
      [ nil, tool_error("invalid_amount", "amount must be a positive number, the price of one billing period.") ]
    end

    # The JSON Schema properties of the billing fields
    def billing_properties
      {
        amount: { type: "number", description: "Price of one billing period, a positive number in the subscription currency" },
        billing_cycle: { type: "string", enum: BILLING_CYCLES, description: "monthly or yearly" },
        expected_day_of_month: { type: "integer", description: "Day of the month it bills (1-31)" },
        expected_month: { type: [ "integer", "null" ], description: "Month it bills (1-12); required for a yearly cycle" },
        next_expected_date: { type: [ "string", "null" ], description: "Next billing date (YYYY-MM-DD). Left out: worked out from the billing day" },
        default_account_id: { type: [ "string", "null" ], description: "Account id from get_accounts that pays it; Sure books each due charge there" },
        category_id: { type: [ "string", "null" ], description: "Category id from get_categories" },
        notes: { type: [ "string", "null" ], description: "Notes" }
      }
    end
end
