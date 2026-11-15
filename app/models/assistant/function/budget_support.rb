# Shared by get_budget and update_budget: which budget a `month` argument names, and the category lookup.
#
# A budget covers one budget period: a calendar month, or a fiscal month that starts on the family's fiscal start
# day. The argument maps through Family#budget_period_start_for, so the chat, /mcp and the budget page agree:
# - blank: the period that contains today (the family's time zone; the chat job and /mcp both switch to it);
# - "2026-03" or "mar-2026" (the budget page's URL form): the period that starts in that month;
# - "2026-03-10": the period that contains that date.
module Assistant::Function::BudgetSupport
  MONTH_FORMAT = /\A(\d{4})-(\d{2})\z/
  DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

  MONTH_DESCRIPTION = "Budget month: YYYY-MM or mmm-yyyy for the period that starts in that month, or " \
    "YYYY-MM-DD for the period that contains that date. Default: the current period."

  private
    # The start date of the budget period the argument names, or nil when it cannot be read
    def budget_period_start(value)
      value = value.to_s.strip
      return family.budget_period_start_for(Date.current) if value.blank?

      date = if (match = MONTH_FORMAT.match(value))
        period_start_in_month(match[1].to_i, match[2].to_i)
      elsif DATE_FORMAT.match?(value)
        Date.iso8601(value)
      else
        Budget.param_to_date(value.downcase, family: family)
      end

      family.budget_period_start_for(date)
    rescue Date::Error, ArgumentError
      nil
    end

    # Same rule as Budget.param_to_date: the fiscal start day, clamped to the month's length
    def period_start_in_month(year, month)
      Date.new(year, month, [ family.fiscal_start_day, Date.new(year, month, -1).day ].min)
    end

    # The error data for a month that cannot be read or lies outside the budget range (back to the oldest entry
    # or two years, whichever is earlier, and forward two years), or nil when the month is fine
    def budget_month_error(value, period_start)
      return tool_error("invalid_month", "month must be YYYY-MM, mmm-yyyy or YYYY-MM-DD.", month: value) if period_start.nil?
      return nil if Budget.budget_date_valid?(period_start, family: family)

      tool_error(
        "month_out_of_range",
        "Budgets reach back to the oldest transaction (or two years, whichever is earlier) and forward two years.",
        month: value
      )
    end

    # An existing budget only: audit snapshots must not create one
    def existing_budget(period_start)
      family.budgets.find_by(start_date: period_start)
    end

    # A category of the family by id or by name (case-insensitive)
    def find_family_category(value)
      value = value.to_s.strip
      return nil if value.blank?

      return family.categories.find_by(id: value) if valid_uuid?(value)

      family.categories.find_by("LOWER(name) = ?", value.downcase)
    end

    def uncategorized_name?(value)
      value.to_s.strip.casecmp?(Category.uncategorized_name)
    end

    # An amount as a number in the family currency, rounded to the currency's precision
    def budget_amount(value)
      precision = Money::Currency.new(family.currency).default_precision
      value.to_d.round(precision).to_f
    rescue Money::Currency::UnknownCurrencyError
      value.to_d.round(2).to_f
    end

    def budget_percent(value)
      value.to_d.round(1).to_f
    end
end
