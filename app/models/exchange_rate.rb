class ExchangeRate < ApplicationRecord
  include Provided

  # Part of the cache key of every cached figure converted into the family currency
  # (ExchangeRate.conversion_cache_key). Those keys follow entries and syncs, not the
  # conversion rule, so a change to the rule bumps this or old figures outlive the deploy.
  # "fx2": a missing rate leaves an amount out rather than counting it at 1.
  CONVERSION_CACHE_VERSION = "fx2"

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
end
