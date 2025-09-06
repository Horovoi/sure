class Family < ApplicationRecord
  include PlaidConnectable, SimplefinConnectable, Syncable, AutoTransferMatchable, Subscribeable

  DATE_FORMATS = [
    [ "MM-DD-YYYY", "%m-%d-%Y" ],
    [ "DD.MM.YYYY", "%d.%m.%Y" ],
    [ "DD-MM-YYYY", "%d-%m-%Y" ],
    [ "YYYY-MM-DD", "%Y-%m-%d" ],
    [ "DD/MM/YYYY", "%d/%m/%Y" ],
    [ "YYYY/MM/DD", "%Y/%m/%d" ],
    [ "MM/DD/YYYY", "%m/%d/%Y" ],
    [ "D/MM/YYYY", "%e/%m/%Y" ],
    [ "YYYY.MM.DD", "%Y.%m.%d" ]
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

  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }
  validates :date_format, inclusion: { in: DATE_FORMATS.map(&:last) }
  validates :fiscal_month_start_day, inclusion: { in: 1..31 }, allow_nil: true

  def assigned_merchants
    merchant_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    Merchant.where(id: merchant_ids)
  end

  def auto_categorize_transactions_later(transactions)
    AutoCategorizeJob.perform_later(self, transaction_ids: transactions.pluck(:id))
  end

  def auto_categorize_transactions(transaction_ids)
    AutoCategorizer.new(self, transaction_ids: transaction_ids).auto_categorize
  end

  def auto_detect_transaction_merchants_later(transactions)
    AutoDetectMerchantsJob.perform_later(self, transaction_ids: transactions.pluck(:id))
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

    # Determine which month contains the start of period for the given date
    base_month = if date.day >= day
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
    next_start = budget_period_start_for(start_date >> 1) # +1 month
    next_start - 1.day
  end

  # Used for invalidating family / balance sheet related aggregation queries
  def build_cache_key(key, invalidate_on_data_updates: false)
    # Our data sync process updates this timestamp whenever any family account successfully completes a data update.
    # By including it in the cache key, we can expire caches every time family account data changes.
    data_invalidation_key = invalidate_on_data_updates ? latest_sync_completed_at : nil

    [
      id,
      key,
      data_invalidation_key,
      accounts.maximum(:updated_at)
    ].compact.join("_")
  end

  # Used for invalidating entry related aggregation queries
  def entries_cache_version
    @entries_cache_version ||= begin
      ts = entries.maximum(:updated_at)
      ts.present? ? ts.to_i : 0
    end
  end

  def self_hoster?
    Rails.application.config.app_mode.self_hosted?
  end
end
