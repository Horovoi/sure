# The entries and holdings one balance calculation reads, converted into the account
# currency once and indexed by date. The calculators ask for every day of the account's
# history, so each lookup is a hash read rather than a scan of the whole history.
#
# Conversion follows the nearest-rate rule (ExchangeRate::Provided), never a rate of 1:
#
# - An entry with no rate at all is left out of the calculation and counted. Converting it
#   at 1 would misstate the balance by the FX gap, and raising would fail every balance of
#   the account over one entry.
# - A holding with no rate keeps its 1:1 value and is counted. Leaving it out would be
#   worse: an investment account's cash is derived as total minus holdings value, so a
#   dropped holding would reappear as cash that does not exist.
#
# report_unconverted_amounts writes one warn DebugLogEntry per calculation with both counts
# and the currency pairs.
class Balance::SyncCache
  def initialize(account)
    @account = account
    @unconvertible_entry_count = 0
    @unconvertible_holding_count = 0
    @missing_rate_pairs = Set.new
    @rates = {}
  end

  # Entries left out because no exchange rate could convert them; zero on a healthy sync
  def unconvertible_entry_count
    entries_by_date
    @unconvertible_entry_count
  end

  # Holdings counted at 1:1 because no exchange rate could convert them
  def unconvertible_holding_count
    holdings_value_by_date
    @unconvertible_holding_count
  end

  def get_valuation(date)
    entries_by_date[date]&.find(&:valuation?)
  end

  # The total value of the day's holdings in the account currency
  def get_holdings_value(date)
    holdings_value_by_date.fetch(date, 0)
  end

  def get_entries(date)
    flow_entries_by_date.fetch(date, [])
  end

  # One warn DebugLogEntry when anything had to be left out or kept at 1:1. Reads only
  # what the calculation already loaded, so a calculation that never touched holdings
  # does not load them here.
  def report_unconverted_amounts
    entries = @entries_by_date ? @unconvertible_entry_count : 0
    holdings = @holdings_value_by_date ? @unconvertible_holding_count : 0
    return if entries.zero? && holdings.zero?

    DebugLogEntry.capture(
      category: "exchange_rates",
      level: "warn",
      source: "Balance::SyncCache",
      message: "Balance of #{account.name}: #{entries} #{"entry".pluralize(entries)} left out and " \
               "#{holdings} #{"holding".pluralize(holdings)} kept at 1:1, no exchange rate into #{account.currency}",
      account: account,
      family: account.family,
      provider_key: exchange_rate_provider_key,
      metadata: {
        account_currency: account.currency,
        unconvertible_entry_count: entries,
        unconvertible_holding_count: holdings,
        missing_rate_pairs: @missing_rate_pairs.to_a.sort
      }
    )
  end

  private
    attr_reader :account

    def entries_by_date
      @entries_by_date ||= converted_entries.group_by(&:date)
    end

    # The calculators ask for a day's transactions and trades several times per day
    def flow_entries_by_date
      @flow_entries_by_date ||= entries_by_date.transform_values do |entries|
        entries.select { |e| e.transaction? || e.trade? }
      end
    end

    # One sum per date from three plucked columns, instead of a record (and a dup of it)
    # per holding row of the whole history
    def holdings_value_by_date
      @holdings_value_by_date ||= account.holdings.pluck(:date, :amount, :currency).each_with_object(Hash.new(0)) do |(date, amount, currency), totals|
        converted = convert(amount, currency, date)

        if converted.nil?
          converted = amount
          @unconvertible_holding_count += 1
        end

        totals[date] += converted
      end
    end

    # The entries are changed in place (amount and currency) instead of dup'ed: to_a builds
    # instances that belong to this cache alone, no identity map is active, and they are
    # never saved, so the dup only allocated a second attribute set per entry.
    def converted_entries
      @converted_entries ||= entries_scope.to_a.filter_map do |entry|
        amount = entry_amount_in_account_currency(entry)

        if amount.nil?
          @unconvertible_entry_count += 1
          next
        end

        entry.amount = amount
        entry.currency = account.currency
        entry
      end
    end

    # Future-dated entries stay in: the calculators extend the history to the latest entry
    # date, and the materializer reads today's balance from the row for today, so a
    # future entry does not count before its date. Filtering them out (upstream) would
    # leave the stored balance for that date wrong until the next sync, since this fork
    # has no job that syncs an account on an entry's date.
    def entries_scope
      account.entries.excluding_pending.order(:date)
    end

    # The one place an entry's amount is converted. A foreign-currency transaction with a
    # rate the user entered (Transaction#exchange_rate) converts at that rate; every other
    # entry follows the nearest-rate rule.
    def entry_amount_in_account_currency(entry)
      return entry.amount if entry.currency == account.currency

      custom_rate = custom_rates[entry.entryable_id] if entry.entryable_type == "Transaction"
      return entry.amount * custom_rate if custom_rate

      convert(entry.amount, entry.currency, entry.date)
    end

    # Transaction id => user-entered rate, read in one query for the transactions that
    # have one, instead of loading every transaction of the history. A stored value that
    # is not a rate above zero is ignored (the market rate applies).
    def custom_rates
      @custom_rates ||= account.entries
        .where(entryable_type: "Transaction")
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where.not(entries: { currency: account.currency })
        .where("transactions.extra ->> 'exchange_rate' IS NOT NULL")
        .pluck(Arel.sql("transactions.id"), Arel.sql("transactions.extra ->> 'exchange_rate'"))
        .each_with_object({}) do |(id, raw), rates|
          rate = begin
            BigDecimal(raw.to_s)
          rescue ArgumentError, TypeError
            nil
          end
          rates[id] = rate if rate&.finite? && rate.positive?
        end
    end

    # nil when the pair has no rate at all
    def convert(amount, currency, date)
      return amount if currency == account.currency

      rate = rate_for(currency, date)
      rate && amount * rate
    end

    # The nearest-rate rule once per currency and date, not once per row
    def rate_for(currency, date)
      key = [ currency, date ]
      return @rates[key] if @rates.key?(key)

      @rates[key] = begin
        Money.new(1, currency).exchange_to(account.currency, date: date).amount
      rescue Money::ConversionError => error
        @missing_rate_pairs << "#{error.from_currency}->#{error.to_currency}"
        nil
      end
    end

    # Which FX backend was configured when the rate came up missing, read from the setting
    # rather than ExchangeRate.provider, which raises on an unknown configuration
    def exchange_rate_provider_key
      ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    rescue StandardError
      nil
    end
end
