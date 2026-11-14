class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }

  # Provisional (gap-filled) prices are re-fetched by every import that covers them,
  # whatever their age. A recent one stays provisional until the provider publishes
  # that day. One older than the importer's lookback window is written as final on its
  # next import (the real price, or a final gap-fill for a non-trading day), so a row
  # that missed its window (no sync for a while) is fixed instead of staying
  # provisional forever.
  # Includes weekends: they get fixed via cascade when weekday prices are fetched.
  scope :refetchable_provisional, -> { where(provisional: true) }
end
