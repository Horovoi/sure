module Provider::SecurityConcept
  extend ActiveSupport::Concern

  Security = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code)
  SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic)
  Price = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)

  # Mixed into a provider error class that means "the provider does not know this
  # security", as opposed to rate limits, outages or configuration problems.
  # Security::HealthChecker counts only these as failed checks.
  SecurityNotFound = Module.new

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    raise NotImplementedError, "Subclasses must implement #search_securities"
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_info"
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_price"
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_prices"
  end
end
