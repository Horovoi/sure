class Holding::PortfolioCache
  attr_reader :account, :use_holdings

  class SecurityNotFound < StandardError
    def initialize(security_id, account_id)
      super("Security id=#{security_id} not found in portfolio cache for account #{account_id}.  This should not happen unless securities were preloaded incorrectly.")
    end
  end

  def initialize(account, use_holdings: false)
    @account = account
    @use_holdings = use_holdings
    @rate_memo = {}
    @stored_rates = {}
    @provider_failed = Set.new
    @unconverted = {}
    load_prices
  end

  def get_trades(date: nil)
    if date.blank?
      trades
    else
      trades.select { |t| t.date == date }
    end
  end

  def get_price(security_id, date, source: nil)
    security = @security_cache[security_id]
    raise SecurityNotFound.new(security_id, account.id) unless security

    if source.present?
      price = security[:prices].select { |p| p.price.date == date && p.source == source }.min_by(&:priority)&.price
    else
      price = security[:prices].select { |p| p.price.date == date }.min_by(&:priority)&.price
    end

    return nil unless price

    Security::Price.new(
      security_id: security_id,
      date: price.date,
      price: price_in_account_currency(price, date),
      currency: account.currency
    )
  end

  # A trade's price in the account currency at the trade's own date, by the nearest-rate
  # rule. nil when the pair has no rate at all: a cost basis built from it would be a
  # guess, so the calculators leave the basis unknown instead.
  def trade_price_in_account_currency(trade, date)
    rate = rate_into_account_currency(trade.currency, date)

    if rate.nil?
      note_unconverted(:trade_price, trade.currency, date)
      return nil
    end

    trade.price * rate
  end

  # Writes one warn DebugLogEntry for this calculation when any price or trade could not
  # be converted, with the counts and the currency pairs. The calculators call it once at
  # the end, so a sync of years of daily prices does not log one entry per day.
  def report_unconverted(source:)
    return if @unconverted.empty?

    pairs = @unconverted.map do |(kind, from), info|
      { kind: kind.to_s, from: from, to: account.currency, count: info[:count], first_date: info[:first_date].to_s, last_date: info[:last_date].to_s }
    end
    prices = pairs.select { |p| p[:kind] == "price" }.sum { |p| p[:count] }
    trades = pairs.select { |p| p[:kind] == "trade_price" }.sum { |p| p[:count] }

    DebugLogEntry.capture(
      category: "exchange_rates",
      level: "warn",
      message: "No exchange rate into #{account.currency}: #{prices} price(s) kept at 1:1, #{trades} purchase(s) left the cost basis unknown",
      source: source,
      account: account,
      metadata: { prices_kept_at_parity: prices, trades_without_cost_basis: trades, pairs: pairs }
    )
  end

  def get_securities
    @security_cache.map { |_, v| v[:security] }
  end

  private
    PriceWithPriority = Data.define(:price, :priority, :source)

    # A price is converted at its own date (it used to be converted at today's rate, so
    # every historical value moved with today's rate). With no rate at all the price is
    # kept at 1:1 and counted: a holding without a value would drop out of the balance and
    # its amount would show up as cash that does not exist.
    def price_in_account_currency(price, date)
      return price.price if price.currency.blank? || price.currency == account.currency

      rate = rate_into_account_currency(price.currency, date)
      return price.price * rate if rate

      note_unconverted(:price, price.currency, date)
      price.price
    end

    # The nearest-rate rule (ExchangeRate::Provided) without a query per day: the stored
    # rate for the day, else the provider's for the day, else the latest stored rate before
    # it, else the earliest after it. The stored rates of each pair are loaded once. The
    # provider is asked at most until it first fails for a pair, so a rate-limited provider
    # cannot turn one sync into a request per day of history.
    def rate_into_account_currency(from, date)
      return 1 if from.blank? || from == account.currency

      @rate_memo[[ from, date ]] ||= [ lookup_rate(from, date) ]
      @rate_memo[[ from, date ]].first
    end

    def lookup_rate(from, date)
      rates = stored_rates_for(from)
      exact = rates[:by_date][date]
      return exact if exact

      unless @provider_failed.include?(from)
        fetched = ExchangeRate.find_or_fetch_rate(from: from, to: account.currency, date: date)&.rate
        return fetched if ExchangeRate.valid_rate?(fetched)

        @provider_failed << from
      end

      nearest_stored_rate(rates[:sorted], date)
    end

    def stored_rates_for(from)
      @stored_rates[from] ||= begin
        rows = ExchangeRate.where(from_currency: from, to_currency: account.currency)
                           .where("exchange_rates.rate > 0")
                           .order(:date)
                           .pluck(:date, :rate)
        { sorted: rows, by_date: rows.to_h }
      end
    end

    # rows are [date, rate] in date order
    def nearest_stored_rate(rows, date)
      return nil if rows.empty?

      after_index = rows.bsearch_index { |(rate_date, _)| rate_date > date }
      if after_index.nil?
        rows.last.last
      elsif after_index.zero?
        rows.first.last
      else
        rows[after_index - 1].last
      end
    end

    def note_unconverted(kind, from, date)
      info = (@unconverted[[ kind, from ]] ||= { count: 0, first_date: date, last_date: date })
      info[:count] += 1
      info[:first_date] = [ info[:first_date], date ].min
      info[:last_date] = [ info[:last_date], date ].max
    end

    def trades
      @trades ||= account.entries.includes(entryable: :security).trades.chronological.to_a
    end

    def holdings
      @holdings ||= account.holdings.chronological.to_a
    end

    def collect_unique_securities
      unique_securities_from_trades = trades.map(&:entryable).map(&:security).uniq

      return unique_securities_from_trades unless use_holdings

      unique_securities_from_holdings = holdings.map(&:security).uniq

      (unique_securities_from_trades + unique_securities_from_holdings).uniq
    end

    # Loads all known prices for all securities in the account with priority based on source:
    # 1 - DB or provider prices
    # 2 - Trade prices
    # 3 - Holding prices
    def load_prices
      @security_cache = {}
      securities = collect_unique_securities

      Rails.logger.info "Preloading #{securities.size} securities for account #{account.id}"

      securities.each do |security|
        Rails.logger.info "Loading security: ID=#{security.id} Ticker=#{security.ticker}"

        # High priority prices from DB (synced from provider)
        db_prices = security.prices.where(date: account.start_date..Date.current).map do |price|
          PriceWithPriority.new(
            price: price,
            priority: 1,
            source: "db"
          )
        end

        # Medium priority prices from trades
        trade_prices = trades
          .select { |t| t.entryable.security_id == security.id }
          .map do |trade|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: trade.entryable.price,
                currency: trade.entryable.currency,
                date: trade.date
              ),
              priority: 2,
              source: "trade"
            )
          end

        # Low priority prices from holdings (if applicable)
        holding_prices = if use_holdings
          holdings.select { |h| h.security_id == security.id }.map do |holding|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: holding.price,
                currency: holding.currency,
                date: holding.date
              ),
              priority: 3,
              source: "holding"
            )
          end
        else
          []
        end

        @security_cache[security.id] = {
          security: security,
          prices: db_prices + trade_prices + holding_prices
        }
      end
    end
end
