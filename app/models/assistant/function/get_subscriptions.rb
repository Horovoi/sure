# Lists the family's subscriptions and recurring rows as the Subscriptions page shows them, with the monthly and
# yearly totals of the active subscriptions in the family currency.
class Assistant::Function::GetSubscriptions < Assistant::Function
  include Assistant::Function::SubscriptionsSupport

  FILTERS = %w[active paused suggested dismissed other_recurring all].freeze
  MAX_UPCOMING_DAYS = 366

  class << self
    def name
      "get_subscriptions"
    end

    def description
      <<~INSTRUCTIONS
        Lists subscriptions and other recurring bills, with what each costs, when
        it bills next and which account pays it.

        filter: active (default, confirmed subscriptions that bill), paused,
        suggested (detected, waiting for review), dismissed, other_recurring
        (recurring bills that are not subscriptions) or all.
        upcoming_days: only rows that bill within that many days from today.
        id: one row by its id (any kind).

        totals sums the active subscriptions per month and per year in the
        family currency, whatever the filter. A row with due: true is due today
        or overdue and can be recorded with record_subscription_charge.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        filter: { type: "string", enum: FILTERS, description: "Which rows to list; default active" },
        upcoming_days: { type: [ "integer", "null" ], description: "Only rows billing within this many days (0-366)" },
        id: { type: [ "string", "null" ], description: "One row by its id" }
      }
    )
  end

  def call(params = {})
    if params["id"].present?
      row = find_recurring_row(params["id"])
      return not_found_error unless row

      return { subscription: subscription_snapshot(row), currency: family.currency, totals: totals }
    end

    filter = params["filter"].presence || "active"
    return tool_error("invalid_filter", "filter must be one of #{FILTERS.join(", ")}.") unless FILTERS.include?(filter)

    rows = filtered(filter)

    if !params["upcoming_days"].nil?
      days = params["upcoming_days"].to_i
      return tool_error("invalid_upcoming_days", "upcoming_days must be 0 to #{MAX_UPCOMING_DAYS}.") unless days.between?(0, MAX_UPCOMING_DAYS)

      rows = rows.active.where(next_expected_date: ..(Date.current + days))
    end

    rows = rows.includes(:merchant, :category, :default_account, :subscription_service)
      .order(:next_expected_date, :name)
      .to_a

    {
      filter: filter,
      currency: family.currency,
      as_of_date: Date.current.iso8601,
      total_results: rows.size,
      subscriptions: rows.map { |row| subscription_snapshot(row) },
      totals: totals
    }
  end

  private
    def filtered(filter)
      case filter
      when "active" then recurring_rows.subscriptions.active
      when "paused" then recurring_rows.subscriptions.inactive
      when "suggested" then recurring_rows.suggested
      when "dismissed" then recurring_rows.dismissed
      when "other_recurring" then recurring_rows.other_recurring
      when "all"
        recurring_rows.where(subscription_state: %w[subscription suggested dismissed]).or(recurring_rows.other_recurring)
      end
    end

    # Like the Subscriptions header: active subscriptions only, a yearly one counted as a twelfth per month. A
    # currency with no rate at all is left out and named.
    def totals
      monthly = Money.new(0, family.currency)
      yearly = Money.new(0, family.currency)
      left_out = []

      recurring_rows.active_subscriptions.find_each do |row|
        per_month = in_family_currency(row.billing_cycle_yearly? ? row.amount_money / 12 : row.amount_money)
        per_year = in_family_currency(row.billing_cycle_monthly? ? row.amount_money * 12 : row.amount_money)

        if per_month && per_year
          monthly += per_month
          yearly += per_year
        else
          left_out << row.currency
        end
      end

      {
        active_count: recurring_rows.active_subscriptions.count,
        monthly: monthly.amount.to_f,
        yearly: yearly.amount.to_f,
        currency: family.currency,
        left_out_currencies: left_out.uniq.presence
      }.compact
    end
end
