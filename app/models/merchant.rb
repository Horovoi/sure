class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

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
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  private
    def detach_recurring_transactions
      RecurringTransaction.reassign_merchant!(recurring_transactions, fallback_name: name)
    end
end
