class Security < ApplicationRecord
  include AASM, Provided

  # ISO 10383 MIC codes mapped to user-friendly exchange names
  # Source: https://www.iso20022.org/market-identifier-codes
  # Data stored in config/exchanges.yml
  EXCHANGES = YAML.safe_load_file(Rails.root.join("config", "exchanges.yml")).freeze

  before_validation :upcase_symbols
  before_save :generate_logo_url_from_brandfetch, if: :should_generate_logo?

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }

  # Whether we may ask the price provider about this security:
  # - online: healthy
  # - degraded: some recent health checks did not find it, still fetched
  # - unavailable: the provider stopped pricing it; never fetched, price history kept,
  #   rechecked by Security::HealthChecker and back to online when found again
  # - manual: entered by the user or not known to the provider; never fetched or checked
  FETCHABLE_STATUSES = %w[online degraded].freeze

  aasm column: :status, whiny_persistence: true do
    state :online, initial: true
    state :degraded
    state :unavailable
    state :manual

    event :record_health_check_success do
      transitions from: %i[online degraded unavailable], to: :online, after: :reset_failed_fetches
    end

    event :record_health_check_failure do
      transitions from: %i[online degraded unavailable], to: :unavailable,
                  guard: :failure_limit_reached?, after: :count_failed_fetch
      transitions from: %i[online degraded], to: :degraded, after: :count_failed_fetch
    end

    event :mark_manual do
      transitions from: %i[online degraded unavailable manual], to: :manual
    end
  end

  scope :fetchable, -> { where(status: FETCHABLE_STATUSES) }

  # `offline` is a legacy mirror of the status, kept so the previous app version still
  # reads it correctly. Nothing in this version reads it.
  before_save { self.offline = !fetchable? }

  # Returns user-friendly exchange name for a MIC code
  def self.exchange_name_for(mic)
    return nil if mic.blank?
    EXCHANGES.dig(mic.upcase, "name") || mic.upcase
  end

  def exchange_name
    self.class.exchange_name_for(exchange_operating_mic)
  end

  def fetchable?
    FETCHABLE_STATUSES.include?(status)
  end

  def current_price
    @current_price ||= find_or_fetch_price
    return nil if @current_price.nil?
    Money.new(@current_price.price, @current_price.currency)
  end

  def to_combobox_option
    ComboboxOption.new(
      symbol: ticker,
      name: name,
      logo_url: logo_url,
      exchange_operating_mic: exchange_operating_mic,
      country_code: country_code
    )
  end

  def brandfetch_icon_url(width: nil, height: nil)
    identifier = extract_domain(website_url) if website_url.present?
    identifier ||= ticker

    Setting.brand_fetch_icon_url(identifier, width: width, height: height)
  end

  private
    def failure_limit_reached?
      failed_fetch_count.to_i + 1 > Security::HealthChecker::MAX_CONSECUTIVE_FAILURES
    end

    def count_failed_fetch
      self.failed_fetch_count = failed_fetch_count.to_i + 1
      self.failed_fetch_at = Time.current
    end

    def reset_failed_fetches
      self.failed_fetch_count = 0
      self.failed_fetch_at = nil
    end

    def extract_domain(url)
      uri = URI.parse(url)
      host = uri.host || url
      host.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      nil
    end

    def upcase_symbols
      self.ticker = ticker.upcase
      self.exchange_operating_mic = exchange_operating_mic.upcase if exchange_operating_mic.present?
    end

    def should_generate_logo?
      url = brandfetch_icon_url
      return false unless url.present?

      return true if logo_url.blank?
      return false unless logo_url.include?("cdn.brandfetch.io")

      website_url_changed? || ticker_changed?
    end

    def generate_logo_url_from_brandfetch
      self.logo_url = brandfetch_icon_url
    end
end
