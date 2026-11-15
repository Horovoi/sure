# Base class for insight generators. A subclass computes one financial signal and
# returns GeneratedInsight values: numbers and names only, never prose. The feed fills
# the English templates (insights.titles / insights.templates) with `facts`.
#
# Generators run inside GenerateInsightsJob, in the family's time zone and without
# Current.family, so every period is built from the family itself. All periods are
# fiscal months (Family#budget_period_start_for), which are calendar months when fiscal
# months are off.
class Insight::Generator
  # facts: template values (formatted amounts, names, percentages); they may change
  # every night without counting as a change.
  # metadata: what the job compares between runs to decide that the numbers changed
  # materially (bucketed), plus subject ids for links. JSON primitives only, so the
  # jsonb round trip leaves it equal.
  GeneratedInsight = Data.define(:kind, :priority, :template_key, :facts, :metadata, :period_start, :dedupe_key)

  class << self
    # The kinds this generator can emit. After a run that completed, a visible insight
    # of these kinds that was not emitted again has had its condition clear.
    def produces(*kinds)
      @produced_kinds = kinds.flatten.map(&:to_s)
    end

    def produced_kinds
      @produced_kinds || []
    end
  end

  def initialize(family)
    @family = family
  end

  def generate
    raise NotImplementedError
  end

  private
    attr_reader :family

    def income_statement
      @income_statement ||= IncomeStatement.new(family)
    end

    def balance_sheet
      @balance_sheet ||= BalanceSheet.new(family)
    end

    def build_insight(kind:, priority:, template_key:, facts:, metadata:, dedupe_key:, period_start: nil)
      GeneratedInsight.new(
        kind: kind,
        priority: priority,
        template_key: template_key,
        facts: facts,
        metadata: metadata,
        period_start: period_start,
        dedupe_key: dedupe_key.to_s
      )
    end

    # --- Fiscal periods ---

    def current_period_start
      family.budget_period_start_for(Date.current)
    end

    # The fiscal period that holds today, from its first day to today
    def current_period_to_date
      Period.custom(start_date: current_period_start, end_date: Date.current)
    end

    # A whole fiscal period, `back` periods before the current one
    def fiscal_period(back:)
      start = current_period_start
      back.times { start = family.budget_period_start_for(start - 1.day) }
      Period.custom(start_date: start, end_date: family.budget_period_end_for(start))
    end

    # Days of the current fiscal period so far, today included
    def elapsed_days
      (Date.current - current_period_start).to_i + 1
    end

    # --- Scale ---

    # Upstream's thresholds were dollar amounts (500 for a low balance, 5,000 for idle
    # cash), which mean nothing in hryvnias. The fork scales them to the family's own
    # spending instead: the median fiscal month of expenses, in the family currency.
    def median_monthly_expense
      @median_monthly_expense ||= income_statement.median_expense(interval: "month", exclude_current_period: true).to_d
    end

    # Cash the reports count: active Depository accounts not excluded from reports
    def cash_accounts
      family.accounts.counted_in_totals.included_in_reports.where(accountable_type: "Depository")
    end

    # A balance in the family currency at today's nearest stored rate, or nil when no
    # rate exists (never counted at 1)
    def in_family_currency(money)
      money.exchange_to(family.currency).amount.to_d
    rescue Money::ConversionError
      nil
    end

    # --- Formatting ---

    def format_money(amount, currency = family.currency)
      Money.new(amount, currency).format
    end

    # Normalizes BigDecimal results, so metadata survives the jsonb round trip
    # unchanged (BigDecimal#as_json is a string, which would read as a change nightly)
    def round(amount, precision = 2)
      amount.to_f.round(precision)
    end

    # A true minus sign (U+2212) for negative display values; raw numbers stay in metadata
    def signed_number(value)
      value.negative? ? "−#{value.abs}" : value.to_s
    end

    def month_name(date)
      I18n.l(date, format: "%B %Y")
    end
end
