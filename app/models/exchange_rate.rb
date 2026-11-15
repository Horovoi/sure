class ExchangeRate < ApplicationRecord
  include Provided

  # Part of the cache key of every cached figure converted into the family currency
  # (ExchangeRate.conversion_cache_key). Those keys follow entries and syncs, not the
  # conversion rule, so a change to the rule bumps this or old figures outlive the deploy.
  # "fx2": a missing rate leaves an amount out rather than counting it at 1.
  CONVERSION_CACHE_VERSION = "fx2"

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
  # A rate multiplies an amount into another currency, so only a finite number above zero
  # is usable (ExchangeRate.valid_rate?). The chk_exchange_rates_rate_positive constraint
  # enforces the same rule for writes that skip validations, such as the importer's
  # upsert_all. A rate of exactly 1 stays valid: pegged currencies convert at parity.
  validate :rate_must_convert_amounts, if: -> { rate.present? }

  private
    def rate_must_convert_amounts
      errors.add(:rate, :greater_than, count: 0) unless self.class.valid_rate?(rate)
    end
end
