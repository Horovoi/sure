class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  NO_MERCHANT_NAME_KEY = "models.merchant.no_merchant"

  # Stable, non-localized transactions filter value of the synthetic "No merchant" option.
  # A real merchant cannot take this name, so it never collides with one.
  NO_MERCHANT_FILTER_VALUE = "__no_merchant__"

  has_many :transactions, dependent: :nullify
  # Not dependent: :destroy. Deleting a merchant must not delete the
  # subscriptions attached to it; they become name-based instead.
  has_many :recurring_transactions

  # An uploaded logo (FamilyMerchant only). Declared on the base class so a list that
  # mixes both types can preload it: includes(merchant: { logo_attachment: :blob }).
  has_one_attached :logo, dependent: :purge_later do |attachable|
    attachable.variant :small, resize_to_fill: [ 128, 128 ], convert: :webp, saver: { quality: 80 }, preprocessed: true
  end

  before_destroy :detach_recurring_transactions, prepend: true

  validates :name, presence: true
  validates :name, exclusion: { in: [ NO_MERCHANT_FILTER_VALUE ] }
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  class << self
    # The synthetic "No merchant" option of the merchant filter (not saved)
    def no_merchant
      new(name: no_merchant_name)
    end

    def no_merchant_name
      I18n.t(NO_MERCHANT_NAME_KEY)
    end
  end

  # The value the merchant filter (q[merchants][]) takes: the name of a real merchant, the
  # sentinel for the synthetic "No merchant"
  def filter_value
    persisted? ? name : NO_MERCHANT_FILTER_VALUE
  end

  private
    def detach_recurring_transactions
      RecurringTransaction.reassign_merchant!(recurring_transactions, fallback_name: name)
    end
end
