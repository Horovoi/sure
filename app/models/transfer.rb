# A Transfer links the outflow leg (money leaving the source account) with the inflow
# leg (money arriving in the destination account).
#
# State lives in two places:
# - `status`: pending (auto-matched, awaiting review) or confirmed (created or confirmed by the user).
# - a RejectedTransfer row for the same pair: the user said "these are not a transfer", so
#   auto-match must never pair them again. Rejecting or removing a transfer records one.
#
# `transactions.kind` on both legs is a stored copy of "this leg is part of a Transfer". The
# Transfer is its only writer: after_create sets the kinds (see .outflow_kind_for) and
# before_destroy sets the surviving legs back to standard.
class Transfer < ApplicationRecord
  include AASM

  belongs_to :inflow_transaction, class_name: "Transaction"
  belongs_to :outflow_transaction, class_name: "Transaction"

  aasm column: :status, whiny_persistence: true do
    state :pending, initial: true
    state :confirmed

    event :confirm do
      transitions from: :pending, to: :confirmed
    end
  end

  validates :inflow_transaction_id, uniqueness: true
  validates :outflow_transaction_id, uniqueness: true

  validate :transfer_has_different_accounts
  validate :transfer_has_same_family
  # These are the rules for pairing two transactions. They are checked when the pair is made;
  # a later edit to a leg (amount, date) is the user's call and must not make the transfer
  # impossible to confirm or annotate.
  validate :transfer_has_opposite_amounts, on: :create
  validate :transfer_within_date_range, on: :create

  after_create :apply_transaction_kinds
  after_create :clear_rejection
  before_destroy :reset_transaction_kinds

  class << self
    # The one rule for the kind of the outflow leg. Every way of making a transfer (Creator,
    # auto-match, manual match, rules) goes through after_create, which uses this.
    def outflow_kind_for(source_account:, destination_account:)
      if destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      elsif investment_like?(destination_account) && !investment_like?(source_account)
        "investment_contribution"
      else
        "funds_movement"
      end
    end

    private
      def investment_like?(account)
        account.investment? || account.crypto?
      end
  end

  # The user says this pair is not a transfer (Reject on an auto-match, or Remove).
  # Records the rejection so auto-match never pairs them again, then removes the transfer.
  def reject!
    Transfer.transaction do
      family&.lock_transfer_matching!
      RejectedTransfer.find_or_create_by!(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id)
      destroy!
    end
  end

  def family
    from_account&.family || to_account&.family
  end

  def date
    inflow_transaction.entry.date
  end

  def sync_account_later
    inflow_transaction&.entry&.sync_account_later
    outflow_transaction&.entry&.sync_account_later
  end

  def to_account
    inflow_transaction&.entry&.account
  end

  def from_account
    outflow_transaction&.entry&.account
  end

  def amount_abs
    inflow_transaction&.entry&.amount_money&.abs
  end

  def name
    acc = to_account
    if payment?
      acc ? "Payment to #{acc.name}" : "Payment"
    else
      acc ? "Transfer to #{acc.name}" : "Transfer"
    end
  end

  def payment?
    to_account&.liability?
  end

  def loan_payment?
    outflow_transaction&.kind == "loan_payment"
  end

  def liability_payment?
    outflow_transaction&.kind == "cc_payment"
  end

  def regular_transfer?
    outflow_transaction&.kind == "funds_movement"
  end

  def transfer_type
    return "loan_payment" if loan_payment?
    return "liability_payment" if liability_payment?
    "transfer"
  end

  def categorizable?
    to_account&.accountable_type == "Loan"
  end

  private
    def apply_transaction_kinds
      inflow_transaction.update!(kind: "funds_movement")

      outflow_kind = self.class.outflow_kind_for(source_account: from_account, destination_account: to_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution" && outflow_transaction.category_id.blank?
        category = family.investment_contributions_category
        outflow_attrs[:category] = category if category
      end

      outflow_transaction.update!(outflow_attrs)
    end

    # Pairing a rejected pair again (manual match, rule) means the user changed their mind.
    def clear_rejection
      RejectedTransfer.where(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id).delete_all
    end

    # Sets the legs that survive this transfer back to standard. When the transfer is destroyed
    # because one of its legs is being destroyed, that leg is left alone.
    def reset_transaction_kinds
      surviving_legs.each do |txn|
        attrs = { kind: "standard" }

        if txn.investment_contribution? && txn.category_id.present? && txn.category_id == family&.investment_contributions_category&.id
          attrs[:category_id] = nil
        end

        txn.update!(attrs)
      end
    end

    def surviving_legs
      gone_key = destroyed_by_association&.foreign_key.to_s

      legs = []
      legs << inflow_transaction unless gone_key == "inflow_transaction_id"
      legs << outflow_transaction unless gone_key == "outflow_transaction_id"
      legs.compact.reject(&:destroyed?)
    end

    def transfer_has_different_accounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, "Must be from different accounts") if to_account == from_account
    end

    def transfer_has_same_family
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, "Must be from same family") unless to_account&.family == from_account&.family
    end

    def transfer_has_opposite_amounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      inflow_entry = inflow_transaction.entry
      outflow_entry = outflow_transaction.entry

      inflow_amount = inflow_entry.amount
      outflow_amount = outflow_entry.amount

      if inflow_entry.currency == outflow_entry.currency
        # For same currency, amounts must be exactly opposite
        errors.add(:base, "Must have opposite amounts") if inflow_amount + outflow_amount != 0
      else
        # For different currencies, just check the signs are opposite
        errors.add(:base, "Must have opposite amounts") unless inflow_amount.negative? && outflow_amount.positive?
      end
    end

    def transfer_within_date_range
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      date_diff = (inflow_transaction.entry.date - outflow_transaction.entry.date).abs
      max_days = confirmed? ? 30 : 4
      errors.add(:base, "Must be within #{max_days} days") if date_diff > max_days
    end
end
