class Provider::Nbu < Provider
  include ExchangeRateConcept

  # Subclass so errors caught in this provider are raised as Provider::Nbu::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)

  BASE_CURRENCY = "UAH".freeze

  def initialize
    # No API key required for NBU
    @fallback_provider = Provider::YahooFinance.new
  end

  def healthy?
    response = client.get("#{base_url}/exchangenew", json: "")
    data = JSON.parse(response.body)
    data.is_a?(Array) && data.any?
  rescue => e
    false
  end

  def usage
    # NBU is a free public API with no usage limits
    with_provider_response do
      UsageData.new(
        used: 0,
        limit: nil,
        utilization: 0,
        plan: "Free (National Bank of Ukraine)"
      )
    end
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    # Delegate to fallback provider for non-UAH pairs
    unless involves_uah?(from, to)
      return @fallback_provider.fetch_exchange_rate(from: from, to: to, date: date)
    end

    with_provider_response do
      # Same currency returns 1.0
      if from == to
        next Rate.new(date: date, from: from, to: to, rate: 1.0)
      end

      # Determine which currency is foreign (not UAH)
      foreign_currency = from == BASE_CURRENCY ? to : from

      response = client.get("#{base_url}/exchangenew") do |req|
        req.params["json"] = ""
        req.params["valcode"] = foreign_currency
        req.params["date"] = format_date(date)
      end

      data = JSON.parse(response.body)

      raise InvalidExchangeRateError, "No exchange rate data returned for #{foreign_currency} on #{date}" if data.empty?

      rate_data = data.first
      nbu_rate = rate_data["rate"].to_d

      # NBU returns rate as "X UAH per 1 unit of foreign currency"
      # If from is UAH, we need to invert (UAH -> foreign = 1/rate)
      # If to is UAH, we use the rate directly (foreign -> UAH = rate)
      final_rate = if from == BASE_CURRENCY
        (1.0 / nbu_rate).round(8)
      else
        nbu_rate
      end

      Rate.new(date: date, from: from, to: to, rate: final_rate)
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    # Delegate to fallback provider for non-UAH pairs
    unless involves_uah?(from, to)
      return @fallback_provider.fetch_exchange_rates(from: from, to: to, start_date: start_date, end_date: end_date)
    end

    with_provider_response do
      validate_date_range!(start_date, end_date)

      # Same currency returns 1.0 for all dates
      if from == to
        next (start_date..end_date).map do |date|
          Rate.new(date: date, from: from, to: to, rate: 1.0)
        end
      end

      # NBU API only returns data for a single date per request
      # We need to iterate through each date in the range
      rates = []
      (start_date..end_date).each do |date|
        rate_response = fetch_exchange_rate(from: from, to: to, date: date)

        if rate_response.success?
          rates << rate_response.data
        else
          # Log but continue - some dates may not have rates (weekends, holidays)
          Rails.logger.warn("#{self.class.name}: No rate for #{from}/#{to} on #{date}")
        end
      end

      raise InvalidExchangeRateError, "No exchange rates found for #{from}/#{to} between #{start_date} and #{end_date}" if rates.empty?

      rates.sort_by(&:date)
    end
  end

  private

    def base_url
      ENV["NBU_URL"] || "https://bank.gov.ua/NBUStatService/v1/statdirectory"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"

        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    def format_date(date)
      date.strftime("%Y%m%d")
    end

    def involves_uah?(from, to)
      from == BASE_CURRENCY || to == BASE_CURRENCY
    end

    def validate_date_range!(start_date, end_date)
      raise Error, "Start date cannot be after end date" if start_date > end_date
      raise Error, "Date range too large (max 1 year)" if end_date > start_date + 1.year
    end

    # Override to preserve custom error subclasses
    def default_error_transformer(error)
      case error
      when Error
        # Already our error type, return as-is
        error
      when Faraday::Error
        Error.new(error.message, details: error.response&.dig(:body))
      else
        Error.new(error.message)
      end
    end
end
