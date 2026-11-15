class ExchangeRate::Importer
  MissingExchangeRateError = Class.new(StandardError)
  MissingStartRateError = Class.new(StandardError)

  # Gap-filled rates for days this recent are provisional: the provider may still publish them
  PROVISIONAL_LOOKBACK_DAYS = 7

  def initialize(exchange_rate_provider:, from:, to:, start_date:, end_date:, clear_cache: false)
    @exchange_rate_provider = exchange_rate_provider
    @from = from
    @to = to
    @start_date = start_date
    @end_date = normalize_end_date(end_date)
    @clear_cache = clear_cache
  end

  # Constructs a daily series of rates for the given currency pair for date range
  def import_provider_rates
    if !clear_cache && all_rates_exist?
      Rails.logger.info("No new rates to sync for #{from} to #{to} between #{start_date} and #{end_date}, skipping")
      return
    end

    if provider_rates.empty?
      Rails.logger.warn("Could not fetch rates for #{from} to #{to} between #{start_date} and #{end_date} because provider returned no rates")
      return
    end

    prev_rate_value = start_rate_value

    unless prev_rate_value.present?
      error = MissingStartRateError.new("Could not find a start rate for #{from} to #{to} between #{start_date} and #{end_date}")
      Rails.logger.error(error.message)
      Sentry.capture_exception(error)
      return
    end

    gapfilled_rates = effective_start_date.upto(end_date).map do |date|
      db_rate = db_rates[date]
      db_rate_value = db_rate&.rate
      provider_rate_value = provider_rates[date]&.rate

      chosen_rate, source = if clear_cache
        provider_rate_value ? [ provider_rate_value, :provider ] : [ db_rate_value, :db ] # overwrite when possible
      elsif db_rate&.provisional
        [ provider_rate_value, :provider ]     # a gap-fill: only a provider rate replaces it
      elsif db_rate_value
        [ db_rate_value, :db ]                 # keep what we have
      else
        [ provider_rate_value, :provider ]     # fill gaps
      end

      # Gapfill with LOCF strategy (last observation carried forward). A rate that cannot
      # convert an amount (nil, zero, negative, NaN, Infinity) is skipped and the previous
      # valid rate carried instead: the chk_exchange_rates_rate_positive constraint would
      # reject the whole upsert batch otherwise.
      unless ExchangeRate.valid_rate?(chosen_rate)
        Rails.logger.warn("Skipping invalid exchange rate #{from}/#{to} on #{date}: #{chosen_rate.inspect}") unless chosen_rate.nil?
        chosen_rate = prev_rate_value
        source = :locf
      end

      prev_rate_value = chosen_rate

      {
        from_currency: from,
        to_currency: to,
        date: date,
        rate: chosen_rate,
        provisional: provisional?(date: date, source: source, db_rate: db_rate)
      }
    end

    upsert_rows(gapfilled_rates)
  end

  private
    attr_reader :exchange_rate_provider, :from, :to, :start_date, :end_date, :clear_cache

    # A provider rate is final. A recent gap-fill is provisional; an old one is final
    # (the provider has no rate for that day, e.g. a weekend). A kept DB rate keeps its flag.
    def provisional?(date:, source:, db_rate:)
      case source
      when :provider then false
      when :locf then date >= PROVISIONAL_LOOKBACK_DAYS.days.ago.to_date
      else db_rate&.provisional || false
      end
    end

    def upsert_rows(rows)
      batch_size = 200

      total_upsert_count = 0

      rows.each_slice(batch_size) do |batch|
        upserted_ids = ExchangeRate.upsert_all(
          batch,
          unique_by: %i[from_currency to_currency date],
          returning: [ "id" ]
        )

        total_upsert_count += upserted_ids.count
      end

      total_upsert_count
    end

    # The rate carried into the first date we fill when that date has none: the latest one known on or
    # before it (the provider may skip weekends and holidays, hence the fetch buffer). Never the rate at
    # start_date when the fill starts later: that one can be years old.
    def start_rate_value
      [ provider_rates, db_rates ].each do |rates|
        value = rates.select { |date, rate| date <= effective_start_date && ExchangeRate.valid_rate?(rate&.rate) }
                     .max_by { |date, _| date }&.last&.rate
        return value if value.present?
      end

      nil
    end

    # No need to fetch/upsert rates for dates that we already have in the DB (unless provisional)
    def effective_start_date
      return start_date if clear_cache

      first_missing_date = nil

      start_date.upto(end_date) do |date|
        if !db_rates.key?(date) || db_rates[date].provisional
          first_missing_date = date
          break
        end
      end

      first_missing_date || end_date
    end

    def provider_rates
      @provider_rates ||= begin
        # Always fetch with a 5 day buffer to ensure we have a starting rate (for weekends and holidays)
        provider_fetch_start_date = effective_start_date - 5.days

        provider_response = exchange_rate_provider.fetch_exchange_rates(
          from: from,
          to: to,
          start_date: provider_fetch_start_date,
          end_date: end_date
        )

        if provider_response.success?
          provider_response.data.index_by(&:date)
        else
          message = "#{exchange_rate_provider.class.name} could not fetch exchange rate pair from: #{from} to: #{to} between: #{effective_start_date} and: #{Date.current}.  Provider error: #{provider_response.error.message}"
          Rails.logger.warn(message)
          Sentry.capture_exception(MissingExchangeRateError.new(message), level: :warning)
          {}
        end
      end
    end

    def all_rates_exist?
      db_count == expected_count && db_rates.values.none?(&:provisional)
    end

    def expected_count
      (start_date..end_date).count
    end

    def db_count
      db_rates.count
    end

    def db_rates
      @db_rates ||= ExchangeRate.where(from_currency: from, to_currency: to, date: start_date..end_date)
                  .order(:date)
                  .to_a
                  .index_by(&:date)
    end

    # Normalizes an end date so that it never exceeds today's date in the
    # America/New_York timezone. If the caller passes a future date we clamp
    # it to today so that upstream provider calls remain valid and predictable.
    def normalize_end_date(requested_end_date)
      today_est = Date.current.in_time_zone("America/New_York").to_date
      [ requested_end_date, today_est ].min
    end
end
