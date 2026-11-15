# Monthly net worth for the Reports page, where each point also carries the balance
# of every account group (one group per accountable type), split into assets and
# liabilities, for the chart tooltip.
#
# The accounts are the ones of past net worth (BalanceSheet::HistoricalAccountScope):
# active accounts on every day, a disabled account only before it was disabled.
#
# Every amount is rounded to the currency's display precision. The chart is drawn from
# the amounts, so a sub-unit residue would plot as a move between two points that print
# the same value. A point's net worth is its rounded asset total minus its rounded
# liability total, so the groups in the tooltip always add up to the value on the line.
class BalanceSheet::NetWorthBreakdownSeriesBuilder
  # One point per month, whatever the length of the period
  INTERVAL = "1 month"
  CACHE_VERSION = "v1"

  def initialize(family)
    @family = family
  end

  def breakdown_series(period:)
    Rails.cache.fetch(cache_key(period), expires_in: Family::AGGREGATE_CACHE_TTL) do
      build(period)
    end
  end

  private
    attr_reader :family

    def build(period)
      groups = group_series(period)
      dates = groups.first&.dig(:series)&.values&.map(&:date) || []
      visible_groups = groups.reject { |group| group[:values_by_date].values.all?(&:zero?) }

      points = dates.map { |date| point_for(date, visible_groups) }

      values = [ nil, *points ].each_cons(2).map do |previous, point|
        # The change from the previous month. The first point has no previous month,
        # so it is flat.
        point.merge(trend: trend(point[:value], (previous || point)[:value]))
      end

      {
        start_date: period.start_date,
        end_date: period.end_date,
        interval: INTERVAL,
        trend: values.any? ? trend(values.last[:value], values.first[:value]) : nil,
        values: values
      }
    end

    def point_for(date, groups)
      point_groups = groups.map do |group|
        {
          name: group[:name],
          color: group[:color],
          classification: group[:classification],
          value: group[:values_by_date].fetch(date, zero)
        }
      end

      assets = classification_total(point_groups, "asset")
      liabilities = classification_total(point_groups, "liability")

      {
        date: date,
        date_formatted: I18n.l(date, format: :long),
        value: assets - liabilities,
        assets: assets,
        liabilities: liabilities,
        groups: point_groups
      }
    end

    def trend(current, previous)
      Trend.new(current: current, previous: previous, favorable_direction: "up")
    end

    def classification_total(point_groups, classification)
      point_groups
        .select { |group| group[:classification] == classification }
        .sum(zero) { |group| group[:value] }
    end

    # Liabilities come back as positive amounts: the "down" direction flips the sign
    # in Balance::ChartSeriesBuilder.
    def group_series(period)
      grouped_accounts.map do |(classification, accountable), accounts|
        series = Balance::ChartSeriesBuilder.new(
          account_ids: accounts.map(&:id),
          account_active_until_dates: historical_scope.active_until_dates.slice(*accounts.map(&:id)),
          currency: family.currency,
          period: period,
          interval: INTERVAL,
          favorable_direction: classification == "asset" ? "up" : "down"
        ).balance_series

        {
          name: I18n.t("accounts.types.#{accountable.name.underscore}", default: accountable.display_name),
          color: accountable.color,
          classification: classification,
          series: series,
          values_by_date: series.values.to_h { |value| [ value.date, value.value.for_display ] }
        }
      end
    end

    # Assets first, then liabilities, each in the order of Accountable::TYPES
    def grouped_accounts
      historical_accounts
        .group_by { |account| [ account.classification, Accountable.from_type(account.accountable_type) ] }
        .reject { |(_classification, accountable), _accounts| accountable.nil? }
        .sort_by do |(classification, accountable), _accounts|
          [ classification == "asset" ? 0 : 1, Accountable::TYPES.index(accountable.name) ]
        end
    end

    def historical_scope
      @historical_scope ||= BalanceSheet::HistoricalAccountScope.new(family)
    end

    def historical_accounts
      @historical_accounts ||= historical_scope.relation.select(:id, :classification, :accountable_type).to_a
    end

    def zero
      Money.new(0, family.currency)
    end

    # Disabling or enabling an account changes accounts.maximum(:updated_at), which
    # family.build_cache_key includes, so the series is rebuilt.
    def cache_key(period)
      key = [
        "balance_sheet_net_worth_breakdown_series",
        CACHE_VERSION,
        period.start_date,
        period.end_date
      ].join("_")

      family.build_cache_key(key, invalidate_on_data_updates: true)
    end
end
