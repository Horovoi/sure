class BalanceSheet::NetWorthSeriesBuilder
  def initialize(family)
    @family = family
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period), expires_in: Family::AGGREGATE_CACHE_TTL) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: historical_accounts.account_ids,
        account_active_until_dates: historical_accounts.active_until_dates,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family

    # Active accounts, and disabled ones for the days before they were disabled
    def historical_accounts
      @historical_accounts ||= BalanceSheet::HistoricalAccountScope.new(family)
    end

    # Disabling or enabling an account changes accounts.maximum(:updated_at), which
    # family.build_cache_key includes, so the series is rebuilt.
    def cache_key(period)
      key = [
        "balance_sheet_net_worth_series_historical",
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(
        key,
        invalidate_on_data_updates: true
      )
    end
end
