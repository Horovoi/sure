class Account::MarketDataImporter
  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Prices are imported first so their currencies are known when deciding which
  # exchange rate pairs the account needs.
  def import_all
    import_security_prices
    import_exchange_rates
  end

  def import_exchange_rates
    return unless needs_exchange_rates?
    return unless ExchangeRate.provider

    pair_dates = {}

    # 1. ENTRY-BASED PAIRS – currencies that differ from the account currency
    account.entries
           .where.not(currency: account.currency)
           .group(:currency)
           .minimum(:date)
           .each do |source_currency, date|
      key = [ source_currency, account.currency ]
      pair_dates[key] = [ pair_dates[key], date ].compact.min

      inverse_key = [ account.currency, source_currency ]
      pair_dates[inverse_key] = [ pair_dates[inverse_key], date ].compact.min
    end

    # 2. ACCOUNT-BASED PAIR – convert the account currency to the family currency (if different)
    if foreign_account?
      key = [ account.currency, account.family.currency ]
      pair_dates[key] = [ pair_dates[key], account.start_date ].compact.min

      inverse_key = [ account.family.currency, account.currency ]
      pair_dates[inverse_key] = [ pair_dates[inverse_key], account.start_date ].compact.min
    end

    # 3. SECURITY PRICE PAIRS – holdings convert each security price into the account
    # currency at the price's own date, so every foreign price currency needs rates from
    # the first date a price for that security is required
    security_price_currency_start_dates.each do |source_currency, date|
      key = [ source_currency, account.currency ]
      pair_dates[key] = [ pair_dates[key], date ].compact.min
    end

    # One pair at a time: a provider failure on one pair must not stop the others
    pair_dates.each do |(source, target), start_date|
      import_pair(source, target, start_date)
    end
  end

  def import_security_prices
    return unless Security.provider

    first_trade_dates = first_required_price_dates

    return if first_trade_dates.empty?

    Security.fetchable.where(id: first_trade_dates.keys).each do |security|
      import_security(security, first_trade_dates[security.id])
    end
  end

  private
    def import_pair(source, target, start_date)
      ExchangeRate.import_provider_rates(
        from: source,
        to: target,
        start_date: start_date,
        end_date: Date.current
      )
    rescue StandardError => e
      report_failure("Exchange rate import #{source}/#{target} failed: #{e.class}: #{e.message}", e,
                     category: "exchange_rates", metadata: { from: source, to: target, start_date: start_date.to_s })
    end

    def import_security(security, start_date)
      security.import_provider_prices(start_date: start_date, end_date: Date.current)
      security.import_provider_details
    rescue StandardError => e
      report_failure("Price import for #{security.ticker} failed: #{e.class}: #{e.message}", e,
                     category: "security_prices", metadata: { security_id: security.id, ticker: security.ticker })
    end

    def report_failure(message, error, category:, metadata:)
      Rails.logger.error("[Account::MarketDataImporter] #{message}")
      DebugLogEntry.capture(
        category: category,
        level: "error",
        message: message,
        source: "Account::MarketDataImporter",
        account: account,
        metadata: metadata.merge(error_class: error.class.name, backtrace: Array(error.backtrace).first(10))
      )
    end

    # Earliest required date per security price currency that differs from the account
    # currency. Securities are shared across families, so the start comes from this
    # account's trades, not from the oldest stored price; a currency whose prices all
    # predate that start (an older listing, recorded through another family) is skipped.
    def security_price_currency_start_dates
      @security_price_currency_start_dates ||= begin
        required = first_required_price_dates

        if required.empty?
          {}
        else
          latest_foreign_price_dates = Security::Price.where(security_id: required.keys)
                                                      .where.not(currency: account.currency)
                                                      .group(:security_id, :currency)
                                                      .maximum(:date)

          latest_foreign_price_dates.each_with_object({}) do |((security_id, currency), latest_date), dates|
            start_date = required[security_id]
            next if start_date.nil? || latest_date < start_date

            dates[currency] = [ dates[currency], start_date ].compact.min
          end
        end
      end
    end

    # The first date we require a price for each security traded in this account,
    # keyed by security id. One grouped query instead of one lookup per security.
    def first_required_price_dates
      @first_required_price_dates ||= account.trades.with_entry
                    .where(entries: { account_id: account.id })
                    .group(:security_id)
                    .minimum("entries.date")
    end

    def needs_exchange_rates?
      has_multi_currency_entries? || foreign_account? || security_price_currency_start_dates.any?
    end

    def has_multi_currency_entries?
      account.entries.where.not(currency: account.currency).exists?
    end

    def foreign_account?
      return false if account.family.nil? # an account whose family is gone (upstream a76aa340d)

      account.currency != account.family.currency
    end
end
