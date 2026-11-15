# How an amount is converted into another currency. One rule everywhere (decision 19):
#
# 1. The stored rate for the day, else the provider's (find_or_fetch_rate).
# 2. Otherwise the latest stored rate before the day, however old.
# 3. Otherwise the earliest stored rate after it.
# 4. With no stored rate at all, the amount is left out of a total. It is never
#    converted at 1: "no rate" and "parity" are different facts.
#
# A stored rate of zero or below is no rate. A newest rate older than
# NEAREST_RATE_LOOKBACK_DAYS is still used, and the pages that show totals say it is stale.
module ExchangeRate::Provided
  extend ActiveSupport::Concern

  # A stored rate this recent counts as current: rates_for reuses it before asking the
  # provider, and a newest rate older than this is reported as stale.
  NEAREST_RATE_LOOKBACK_DAYS = 7

  # How long one left-out amount (source, pair and date) stays reported in the debug log
  LEFT_OUT_LOG_INTERVAL = 1.day

  class_methods do
    def provider
      provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
      registry = Provider::Registry.for_concept(:exchange_rates)
      registry.get_provider(provider.to_sym)
    end

    # The stored rate for the day, else the provider's. nil when neither has one; a stored
    # rate of zero or below is skipped, so the provider is still asked.
    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = usable_rates.find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      return nil unless provider.present? # No provider configured (some self-hosted apps)

      # Ask the provider once per pair and date within a request or job, not once per caller
      ExchangeRate::FetchMemo.fetch([ from.to_s, to.to_s, date.to_date, cache ]) do
        fetch_rate_from_provider(from: from, to: to, date: date, cache: cache)
      end
    end

    # The rate the nearest-rate rule gives for converting `from` into `to` on `date`: the
    # day's (stored or from the provider), else the latest stored one before it however
    # old, else the earliest stored one after it. Responds to #rate and #date. nil only
    # when no usable rate into `to` is stored at all.
    def find_rate(from:, to:, date: Date.current)
      rate = find_or_fetch_rate(from: from, to: to, date: date)
      return rate if rate && valid_rate?(rate.rate)

      nearest_stored_rate(from: from, to: to, date: date)
    end

    # The latest usable stored rate on or before `date`, else the earliest one after it
    def nearest_stored_rate(from:, to:, date:)
      scope = usable_rates.where(from_currency: from, to_currency: to)

      scope.where("exchange_rates.date <= ?", date).order(date: :desc).first ||
        scope.where("exchange_rates.date > ?", date).order(:date).first
    end

    # Converts money into `to` by the nearest-rate rule. With no rate at all it returns nil
    # and writes a warn DebugLogEntry (once a day per source, pair and date), so the caller
    # leaves the amount out of its total instead of counting it at 1.
    def convert_or_leave_out(money, to:, date: Date.current, source:, family: nil)
      money = Money.new(money) unless money.is_a?(Money)
      return money if money.currency.iso_code == Money::Currency.new(to).iso_code

      money.exchange_to(to, date: date)
    rescue Money::ConversionError
      report_left_out_amount(from: money.currency.iso_code, to: to, date: date, source: source, family: family)
      nil
    end

    # A rate can convert an amount only when it is a finite number above zero
    def valid_rate?(value)
      return false if value.nil?

      number = value.is_a?(Numeric) ? value : BigDecimal(value.to_s)
      number.finite? && number.positive?
    rescue ArgumentError, TypeError
      false
    end

    # Batch-fetches the rates that convert each of `currencies` into `to` on `date`, as a
    # hash of currency to numeric rate: the day's, else a recent one, else the provider's,
    # else the latest stored one however old, else the earliest stored one after the day.
    # A currency with no stored rate at all is left out of the hash rather than given 1;
    # each caller decides what an absent rate means for its figure. `to` converts at 1.
    def rates_for(currencies, to:, date: Date.current)
      unique_currencies = currencies.compact.uniq - [ to ]
      same = currencies.include?(to) ? { to => 1 } : {}
      return same if unique_currencies.empty?

      exact_rates = usable_rates.where(from_currency: unique_currencies, to_currency: to, date: date)
                                .index_by(&:from_currency)

      missing = unique_currencies - exact_rates.keys

      # For currencies without an exact match, the nearest recent rate in one query
      nearest_rates = if missing.any?
        usable_rates.where(from_currency: missing, to_currency: to)
          .where(date: (date - NEAREST_RATE_LOOKBACK_DAYS)..date)
          .order(date: :desc)
          .to_a
          .each_with_object({}) { |rate, map| map[rate.from_currency] ||= rate }
      else
        {}
      end

      still_missing = missing - nearest_rates.keys

      # The provider only for currencies with no recent rate. Its rate counts only once it
      # is stored as usable: rate_sql and currencies_without_rate read the table, and a rate
      # they cannot see would put an amount in these totals that theirs leave out.
      fetched_rates = still_missing.each_with_object({}) do |currency, map|
        rate = find_or_fetch_rate(from: currency, to: to, date: date)
        next unless rate && valid_rate?(rate.rate)
        next unless usable_rates.exists?(from_currency: currency, to_currency: to, date: rate.date)

        map[currency] = rate
      end

      # A rate from any distance is closer to the truth than 1
      unfetched = still_missing - fetched_rates.keys
      stored_rates = unfetched.any? ? any_stored_rates(unfetched, to: to, date: date) : {}

      unique_currencies.each_with_object(same) do |currency, result|
        rate = exact_rates[currency] || nearest_rates[currency] || fetched_rates[currency] || stored_rates[currency]

        if rate.nil?
          Rails.logger.warn("No exchange rate found for #{currency}/#{to} on #{date}")
          next
        elsif rate.date != date
          Rails.logger.debug("FX rate #{currency}/#{to}: using #{rate.date} for #{date} (gap=#{(date - rate.date).to_i}d)")
        end

        result[currency] = rate.rate
      end
    end

    # SQL for the rate that converts `from` into `to` on `on`, by the same rule without the
    # provider: 1 for the same currency, else the latest stored rate on or before the day,
    # else the earliest after it, else NULL. An amount multiplied by a NULL rate drops out
    # of a SUM, which is the point: it is left out, never counted at parity. Wrap each SUM
    # in COALESCE(..., 0).
    #
    # The arguments are SQL expressions: column names, named binds (":target_currency") or
    # quoted values, never raw user input.
    def rate_sql(from:, to:, on:)
      <<~SQL.squish
        (CASE WHEN #{from} = #{to} THEN 1 ELSE COALESCE(
          (SELECT fx.rate FROM exchange_rates fx
            WHERE fx.from_currency = #{from} AND fx.to_currency = #{to} AND fx.date <= #{on} AND fx.rate > 0
            ORDER BY fx.date DESC LIMIT 1),
          (SELECT fx.rate FROM exchange_rates fx
            WHERE fx.from_currency = #{from} AND fx.to_currency = #{to} AND fx.date > #{on} AND fx.rate > 0
            ORDER BY fx.date ASC LIMIT 1)
        ) END)
      SQL
    end

    # Of `currencies`, those with no usable stored rate into `to` on any date. rate_sql
    # leaves amounts in these out; rates_for and find_rate do too unless the provider
    # supplies a rate.
    def currencies_without_rate(currencies, to:)
      candidates = currencies.compact.uniq - [ to ]
      return [] if candidates.empty?

      candidates - usable_rates.where(from_currency: candidates, to_currency: to).distinct.pluck(:from_currency)
    end

    # Of `currencies`, those whose newest stored rate into `to` on or before `as_of` is
    # older than NEAREST_RATE_LOOKBACK_DAYS, mapped to that rate's date. Today's figures in
    # them convert at that old rate. A currency with no rate at all is not here (see
    # currencies_without_rate).
    def stale_rate_dates(currencies, to:, as_of: Date.current)
      candidates = currencies.compact.uniq - [ to ]
      return {} if candidates.empty?

      # A row dated after as_of must not hide that today's rate is old
      usable_rates.where(from_currency: candidates, to_currency: to, date: ..as_of)
        .group(:from_currency)
        .maximum(:date)
        .select { |_, date| date < as_of - NEAREST_RATE_LOOKBACK_DAYS }
    end

    # Part of the cache key of every cached figure converted into `to`. Changes with the
    # conversion rule (CONVERSION_CACHE_VERSION) and whenever a rate into `to` is stored or
    # updated, so a cache built before the day's rate arrived is replaced.
    def conversion_cache_key(to)
      [
        ExchangeRate::CONVERSION_CACHE_VERSION,
        where(to_currency: to).maximum(:updated_at)&.to_f
      ].join(":")
    end

    # Records that an amount in `from` could not be converted into `to` and was left out of
    # a total: a Rails log line, and a warn DebugLogEntry once a day per source, pair and date.
    def report_left_out_amount(from:, to:, date:, source:, family:)
      Rails.logger.warn("No exchange rate from #{from} to #{to} for #{date}; #{source} leaves the amount out")

      # write(unless_exist:) is an atomic SET NX on Redis: a page that renders on every
      # request reports each left-out amount once a day, not once per view
      cache_key = [ "exchange_rate_left_out", family&.id, source.to_s, from, to.to_s, date.to_s ]
      return unless Rails.cache.write(cache_key, true, expires_in: LEFT_OUT_LOG_INTERVAL, unless_exist: true)

      DebugLogEntry.capture(
        category: "exchange_rates",
        level: "warn",
        message: "No exchange rate from #{from} to #{to}; an amount on #{date} is left out",
        source: source.to_s,
        family: family,
        metadata: { currency: from, to_currency: to.to_s, date: date.to_s }
      )
    rescue StandardError
      nil
    end

    # @return [Integer] The number of exchange rates synced
    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false)
      unless provider.present?
        Rails.logger.warn("No provider configured for ExchangeRate.import_provider_rates")
        return 0
      end

      ExchangeRate::Importer.new(
        exchange_rate_provider: provider,
        from: from,
        to: to,
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      ).import_provider_rates
    end

    private
      # Rows a conversion may use
      def usable_rates
        where("exchange_rates.rate > 0")
      end

      # The latest usable stored rate on or before `date` for each currency, else the
      # earliest one after it, in two queries
      def any_stored_rates(currencies, to:, date:)
        before = usable_rates.where(from_currency: currencies, to_currency: to).where("exchange_rates.date <= ?", date)
                             .select("DISTINCT ON (exchange_rates.from_currency) exchange_rates.*")
                             .order(:from_currency, date: :desc)
                             .index_by(&:from_currency)
        rest = currencies - before.keys
        return before if rest.empty?

        after = usable_rates.where(from_currency: rest, to_currency: to).where("exchange_rates.date > ?", date)
                            .select("DISTINCT ON (exchange_rates.from_currency) exchange_rates.*")
                            .order(:from_currency, :date)
                            .index_by(&:from_currency)
        before.merge(after)
      end

      def fetch_rate_from_provider(from:, to:, date:, cache:)
        response = provider.fetch_exchange_rate(from: from, to: to, date: date)

        return nil unless response.success? # Provider error

        rate = response.data
        return nil unless valid_rate?(rate&.rate)
        return rate unless cache

        begin
          ExchangeRate.find_or_create_by!(
            from_currency: rate.from,
            to_currency: rate.to,
            date: rate.date
          ) do |exchange_rate|
            exchange_rate.rate = rate.rate
          end
        rescue ActiveRecord::RecordNotUnique
          # Race condition: another process inserted between our SELECT and INSERT.
          # The provider's answer stands either way.
          nil
        end
        rate
      end
  end
end
