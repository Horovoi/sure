class Family < ApplicationRecord
  include CoinbaseConnectable
  include PlaidConnectable, LunchflowConnectable, EnableBankingConnectable, Syncable, AutoTransferMatchable, CoinstatsConnectable
  include VectorSearchable

  DATE_FORMATS = [
    [ "MM-DD-YYYY", "%m-%d-%Y" ],
    [ "DD.MM.YYYY", "%d.%m.%Y" ],
    [ "DD-MM-YYYY", "%d-%m-%Y" ],
    [ "YYYY-MM-DD", "%Y-%m-%d" ],
    [ "DD/MM/YYYY", "%d/%m/%Y" ],
    [ "YYYY/MM/DD", "%Y/%m/%d" ],
    [ "MM/DD/YYYY", "%m/%d/%Y" ],
    [ "D/MM/YYYY", "%e/%m/%Y" ],
    [ "YYYY.MM.DD", "%Y.%m.%d" ],
    [ "YYYYMMDD", "%Y%m%d" ]
  ].freeze

  has_many :users, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy

  has_many :imports, dependent: :destroy
  has_many :family_exports, dependent: :destroy

  has_many :entries, through: :accounts
  has_many :transactions, through: :accounts
  has_many :rules, dependent: :destroy
  has_many :trades, through: :accounts
  has_many :holdings, through: :accounts

  has_many :tags, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :merchants, dependent: :destroy, class_name: "FamilyMerchant"

  has_many :budgets, dependent: :destroy
  has_many :budget_categories, through: :budgets

  has_many :llm_usages, dependent: :destroy
  has_many :recurring_transactions, dependent: :destroy

  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }
  validates :date_format, inclusion: { in: DATE_FORMATS.map(&:last) }
  validates :fiscal_month_start_day, inclusion: { in: 1..31 }, allow_nil: true

  # Time zone and currency (w1-fx family-tz-currency-validation). Both are checked only
  # when they change, so a family with an old bad value can still save other changes.
  validate :timezone_must_be_a_known_zone, if: :timezone_changed?
  validate :currency_must_be_known, if: :currency_changed?
  before_validation :normalize_currency

  def assigned_merchants
    merchant_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    Merchant.where(id: merchant_ids)
  end

  def available_merchants
    assigned_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: self)
      .recently_unlinked
      .pluck(:merchant_id)
    family_merchant_ids = merchants.pluck(:id)
    Merchant.where(id: (assigned_ids + recently_unlinked_ids + family_merchant_ids).uniq)
  end

  def auto_categorize_transactions_later(transactions, rule_run_id: nil)
    AutoCategorizeJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  # --- Bayes categorizer (bayes-categorizer) ---------------------------------
  # The local classifier goes first; the LLM gets only what it was not sure of,
  # and only when an LLM provider is configured. Returns the modified count.
  def auto_categorize_transactions(transaction_ids)
    bayes_result = BayesCategorizer.new(self).classify_and_apply(transaction_ids)
    remaining_ids = Array(transaction_ids) - bayes_result.categorized_ids
    return bayes_result.modified_count if remaining_ids.empty?

    llm = AutoCategorizer.new(self, transaction_ids: remaining_ids)
    unless llm.provider_available?
      # Nothing at all was categorized and nothing could be: report it like before,
      # so the rule run shows the missing provider instead of "success, 0 modified"
      raise AutoCategorizer::Error, "No LLM provider for auto-categorization" if bayes_result.categorized_ids.empty?

      Rails.logger.info("Bayes categorized #{bayes_result.categorized_ids.size} transactions for family #{id}; no LLM provider for the other #{remaining_ids.size}")
      return bayes_result.modified_count
    end

    bayes_result.modified_count + llm.auto_categorize
  end

  # Runs the local classifier over a transaction scope (the "Categorize with the
  # local classifier" rule action). Returns the modified count.
  def bayes_categorize(transaction_scope)
    BayesCategorizer.new(self).classify_and_apply(transaction_scope.select(:id)).modified_count
  end
  # --- end Bayes categorizer -------------------------------------------------

  def auto_detect_transaction_merchants_later(transactions, rule_run_id: nil)
    AutoDetectMerchantsJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  def auto_detect_transaction_merchants(transaction_ids)
    AutoMerchantDetector.new(self, transaction_ids: transaction_ids).auto_detect
  end

  def balance_sheet
    @balance_sheet ||= BalanceSheet.new(self)
  end

  def income_statement
    @income_statement ||= IncomeStatement.new(self)
  end

  # Returns the Investment Contributions category for this family, or nil if not found.
  # This is a bootstrapped category used for auto-categorizing transfers to investment accounts.
  def investment_contributions_category
    categories.find_by(name: Category.investment_contributions_name)
  end

  def investment_statement
    @investment_statement ||= InvestmentStatement.new(self)
  end

  def eu?
    country != "US" && country != "CA"
  end

  def requires_securities_data_provider?
    # If family has any trades, they need a provider for historical prices
    trades.any?
  end

  def requires_exchange_rates_data_provider?
    # If family has any accounts not denominated in the family's currency, they need a provider for historical exchange rates
    return true if accounts.where.not(currency: self.currency).any?

    # If family has any entries in different currencies, they need a provider for historical exchange rates
    uniq_currencies = entries.pluck(:currency).uniq
    return true if uniq_currencies.count > 1
    return true if uniq_currencies.count > 0 && uniq_currencies.first != self.currency

    false
  end

  def missing_data_provider?
    (requires_securities_data_provider? && Security.provider.nil?) ||
    (requires_exchange_rates_data_provider? && ExchangeRate.provider.nil?)
  end

  def oldest_entry_date
    entries.order(:date).first&.date || Date.current
  end

  # ---------------------------------------------------------------------------
  # Budget / Fiscal month helpers
  # ---------------------------------------------------------------------------
  def fiscal_month_enabled?
    use_fiscal_months && fiscal_month_start_day.present? && fiscal_month_start_day > 1
  end

  # Returns the effective start day to use (1..31); when not enabled returns 1
  def fiscal_start_day
    (fiscal_month_enabled? ? fiscal_month_start_day : 1) || 1
  end

  # Compute the start date of the budget period that includes the given date
  def budget_period_start_for(date)
    # Normalize to Date to safely use month arithmetic (<<, >>)
    date = date.to_date
    day = fiscal_start_day

    # Determine which month contains the start of period for the given date. The start
    # day is clamped to the month's length, so with day 31 the November period starts
    # on November 30.
    base_month = if date.day >= [ day, date.end_of_month.day ].min
      Date.new(date.year, date.month, 1)
    else
      (date << 1).beginning_of_month
    end

    last_dom = Date.new(base_month.year, base_month.month, -1).day
    start_day = [ day, last_dom ].min
    Date.new(base_month.year, base_month.month, start_day)
  end

  # Compute the inclusive end date for the budget period starting at start_date
  def budget_period_end_for(start_date)
    # The next period starts in the month after this one, on the clamped start day.
    # Stepping the start date by a month instead would keep a clamped day (Feb 28 to
    # Mar 28) and end the period before it began.
    next_month = budget_period_start_for(start_date).next_month.beginning_of_month
    next_start = Date.new(next_month.year, next_month.month, [ fiscal_start_day, next_month.end_of_month.day ].min)
    next_start - 1.day
  end

  # Every aggregate cache (balance sheet, net worth, income statement, search and
  # investment totals) expires after this, as a safety net for any write path that
  # changes data without changing a key below.
  AGGREGATE_CACHE_TTL = 12.hours

  # Used for invalidating family / balance sheet related aggregation queries
  def build_cache_key(key, invalidate_on_data_updates: false)
    # Our data sync process updates this timestamp whenever any family account finishes a data update.
    # By including it in the cache key, we can expire caches every time family account data changes.
    data_invalidation_key = invalidate_on_data_updates ? latest_sync_completed_at&.to_f : nil

    [
      id,
      key,
      data_invalidation_key,
      accounts.maximum(:updated_at)&.to_f,
      currency,
      # Balances are converted at today's rate: a new day means a new rate
      Date.current.iso8601,
      # The conversion rule's version, and the newest rate into the family currency: a
      # cache built before the day's rate arrived is replaced once it is stored
      ExchangeRate.conversion_cache_key(currency)
    ].compact.join("_")
  end

  # Used for invalidating entry related aggregation queries. Changes on any entry
  # create/update/delete (the count catches deletes, which leave max(updated_at) as is),
  # account change (status, currency), category change or delete, and family currency.
  # Sub-second precision so two writes in one second still produce different keys.
  def entries_cache_version
    @entries_cache_version ||= begin
      # One round trip: this runs on every report and transactions page
      row = self.class.connection.select_one(self.class.sanitize_sql_array([ <<~SQL.squish, { id: id } ]))
        SELECT
          (SELECT EXTRACT(EPOCH FROM MAX(e.updated_at)) FROM entries e JOIN accounts a ON a.id = e.account_id WHERE a.family_id = :id) AS entries_max,
          (SELECT COUNT(*) FROM entries e JOIN accounts a ON a.id = e.account_id WHERE a.family_id = :id) AS entries_count,
          (SELECT EXTRACT(EPOCH FROM MAX(updated_at)) FROM accounts WHERE family_id = :id) AS accounts_max,
          (SELECT EXTRACT(EPOCH FROM MAX(updated_at)) FROM categories WHERE family_id = :id) AS categories_max,
          (SELECT COUNT(*) FROM categories WHERE family_id = :id) AS categories_count
      SQL

      [
        row["entries_max"].to_f,
        row["entries_count"],
        row["accounts_max"]&.to_f,
        row["categories_max"]&.to_f,
        row["categories_count"],
        currency
      ].join(":")
    end
  end

  def self_hoster?
    Rails.application.config.app_mode.self_hosted?
  end

  # ---------------------------------------------------------------------------
  # Subscriptions iCal feed (w1-budrec). Off until enabled; the token in the
  # feed URL is the only credential, so reset replaces it and disable clears it.
  # ---------------------------------------------------------------------------
  def self.find_by_subscriptions_feed_token(token)
    return nil if token.blank?

    find_by(subscriptions_feed_token: token.to_s)
  end

  def subscriptions_feed_enabled?
    subscriptions_feed_token.present?
  end

  def enable_subscriptions_feed!
    subscriptions_feed_enabled? ? subscriptions_feed_token : reset_subscriptions_feed!
  end

  def reset_subscriptions_feed!
    update!(subscriptions_feed_token: SecureRandom.urlsafe_base64(32))
    subscriptions_feed_token
  end

  def disable_subscriptions_feed!
    update!(subscriptions_feed_token: nil)
  end

  # --- Time zone and currency (w1-fx family-tz-currency-validation) ---

  # How often a stored time zone that cannot be resolved is written to the debug log.
  # Requests and jobs resolve it all the time, so without this a bad value would write
  # one entry per page view.
  INVALID_TIME_ZONE_LOG_INTERVAL = 1.day

  # The family's time zone for Time.use_zone: requests, jobs and syncs. A blank zone, or
  # one ActiveSupport does not know (a renamed zone, a value written past validation),
  # gives UTC instead of raising, so a bad value can never take down every page.
  def resolved_time_zone
    return @resolved_time_zone if defined?(@resolved_time_zone_for) && @resolved_time_zone_for == timezone

    @resolved_time_zone_for = timezone
    @resolved_time_zone = (ActiveSupport::TimeZone[timezone] if timezone.present?) || begin
      log_invalid_time_zone if timezone.present?
      ActiveSupport::TimeZone["UTC"]
    end
  end

  # Upper-case ISO code for a known currency ("uah" gives "UAH"), nil for anything else
  def self.normalize_currency_code(value)
    return if value.blank?

    Money::Currency.new(value.to_s.strip).iso_code
  rescue Money::Currency::UnknownCurrencyError, ArgumentError
    nil
  end

  private def log_invalid_time_zone
    # write(unless_exist:) is an atomic SET NX on Redis: one writer a day per bad value
    cache_key = [ "invalid_family_time_zone", id, timezone ]
    return unless Rails.cache.write(cache_key, true, expires_in: INVALID_TIME_ZONE_LOG_INTERVAL, unless_exist: true)

    DebugLogEntry.capture(
      category: "time_zone",
      level: "warn",
      message: "Family time zone #{timezone.inspect} is not a known zone; using UTC",
      source: "Family#resolved_time_zone",
      family: self,
      metadata: { timezone: timezone }
    )
  rescue StandardError
    nil
  end

  # ActiveSupport::TimeZone[] resolves both the identifier the preferences form submits
  # ("Europe/Kyiv") and a Rails zone name ("Kyiv"), the same lookup resolved_time_zone uses
  private def timezone_must_be_a_known_zone
    return if timezone.blank?

    errors.add(:timezone, :invalid) if ActiveSupport::TimeZone[timezone].nil?
  end

  private def normalize_currency
    self.currency = self.class.normalize_currency_code(currency) || currency
  end

  private def currency_must_be_known
    errors.add(:currency, :invalid) if self.class.normalize_currency_code(currency).nil?
  end

  # --- Exchange rate notes (w1-fx nearest-rate) ---

  # Currencies the family's visible accounts, entries, trades, holdings or active
  # subscriptions use that have no stored exchange rate into the family currency on any
  # date. Totals leave amounts in them out rather than counting them at 1, and the
  # dashboard, Reports and Transactions pages say so (shared/_exchange_rate_notes).
  # Each one is also written to the debug log (once a day), since the SQL totals that
  # leave its amounts out cannot report them one by one.
  def currencies_without_exchange_rate
    @currencies_without_exchange_rate ||= ExchangeRate.currencies_without_rate(exchange_rate_currencies_in_use, to: currency).tap do |missing|
      missing.each do |from|
        ExchangeRate.report_left_out_amount(from: from, to: currency, date: Date.current, source: "Family#currencies_without_exchange_rate", family: self)
      end
    end
  end

  # Currencies today's totals convert whose newest rate into the family currency is older
  # than ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS, mapped to that rate's date. Today's
  # totals still use it, and the same pages say so. Only balances, current holdings and
  # active subscriptions count: an old entry converts at its own date's rate.
  def stale_exchange_rate_dates
    @stale_exchange_rate_dates ||= ExchangeRate.stale_rate_dates(exchange_rate_currencies_held_now, to: currency)
  end

  # Visible accounts' balances, each account's holdings on its latest holding date, and
  # active subscriptions
  private def exchange_rate_currencies_held_now
    account_ids = accounts.visible.select(:id)
    latest = Holding.where(account_id: account_ids).group(:account_id).select("account_id, MAX(date) AS date")

    (
      Account.where(id: account_ids).distinct.pluck(:currency) +
        Holding.joins("JOIN (#{latest.to_sql}) latest ON latest.account_id = holdings.account_id AND latest.date = holdings.date")
          .distinct.pluck(:currency) +
        recurring_transactions.active_subscriptions.distinct.pluck(:currency)
    ).compact.uniq
  end

  # Memoized: the notes partial reads both lists in one render
  private def exchange_rate_currencies_in_use
    @exchange_rate_currencies_in_use ||= begin
      account_ids = accounts.visible.select(:id)

      (
        Account.where(id: account_ids).distinct.pluck(:currency) +
          Entry.where(account_id: account_ids).distinct.pluck(:currency) +
          Trade.joins(:entry).where(entries: { account_id: account_ids }).distinct.pluck("trades.currency") +
          Holding.where(account_id: account_ids).distinct.pluck(:currency) +
          recurring_transactions.active_subscriptions.distinct.pluck(:currency)
      ).compact.uniq
    end
  end

  # --- Enabled currencies (w1-ds money field) ---
  # enabled_currencies narrows the money fields' currency pickers. NULL means
  # every currency. The base currency is always part of the list, and a
  # record's own currency is added by the caller (`extra:`), so an amount in a
  # currency that was turned off later still shows its currency.

  def primary_currency_code
    self.class.normalize_currency_code(currency) || "USD"
  end

  def custom_enabled_currencies?
    enabled_currencies.present?
  end

  def enabled_currency_codes(extra: [])
    selected_codes = if custom_enabled_currencies?
      [ primary_currency_code, *Array(enabled_currencies) ]
    else
      Money::Currency.as_options.map(&:iso_code)
    end

    self.class.normalize_currency_codes([ *selected_codes, *Array(extra) ])
  end

  def enabled_currency_objects(extra: [])
    enabled_currency_codes(extra:).map { |code| Money::Currency.new(code) }
  end

  def secondary_enabled_currency_objects(extra: [])
    enabled_currency_objects(extra:).reject { |currency| currency.iso_code == primary_currency_code }
  end

  def self.normalize_currency_codes(values)
    Array(values).filter_map { |value| normalize_currency_code(value) }.uniq
  end

  # normalize_currency_code is defined in the w1-fx block above

  before_validation :normalize_enabled_currencies

  # Blank, or every currency ticked, is stored as NULL ("all"), so a currency
  # added to config/currencies.yml later is offered without a settings change.
  # Unknown codes are dropped, and the base currency is always kept.
  # (private def, not a bare private, so blocks appended later stay public)
  private def normalize_enabled_currencies
    return unless will_save_change_to_enabled_currencies? || enabled_currencies.present?

    if enabled_currencies.blank?
      self.enabled_currencies = nil
      return
    end

    normalized_codes = self.class.normalize_currency_codes([ primary_currency_code, *Array(enabled_currencies) ])
    all_codes = Money::Currency.as_options.map(&:iso_code)
    all_selected = normalized_codes.size == all_codes.size && (normalized_codes - all_codes).empty?
    self.enabled_currencies = all_selected ? nil : normalized_codes
  end
end
