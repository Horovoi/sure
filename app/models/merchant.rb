class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  has_many :transactions, dependent: :nullify
  # Not dependent: :destroy. Deleting a merchant must not delete the
  # subscriptions attached to it; they become name-based instead.
  has_many :recurring_transactions

  before_destroy :detach_recurring_transactions, prepend: true

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  private
    def detach_recurring_transactions
      RecurringTransaction.reassign_merchant!(recurring_transactions, fallback_name: name)
    end
end
