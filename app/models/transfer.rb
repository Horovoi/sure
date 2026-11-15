# A Transfer links the outflow leg (money leaving the source account) with the inflow
# leg (money arriving in the destination account).
#
# State lives in two places:
# - `status`: pending (auto-matched, awaiting review) or confirmed (created or confirmed by the user).
# - a RejectedTransfer row for the same pair: the user said "these are not a transfer", so
#   auto-match must never pair them again. Rejecting or removing a transfer records one.
#
# `transactions.kind` on both legs is a stored copy of "this leg is part of a confirmed
# Transfer". The Transfer is its only writer:
# - a transfer created confirmed (Creator, manual match, rules) sets the kinds on create;
# - a pending one (an auto-match) leaves the legs as they are, so an unreviewed suggestion
#   never moves budgets or reports, and the confirm event sets them;
# - reject and destroy set the surviving legs' transfer kinds back to standard.
class Transfer < ApplicationRecord
  include AASM

  # inverse_of (both sides, see Transaction::Transferable): a row asks its transfer
  # whether it is categorizable, which reads both legs' accounts. With the inverse the
  # row's own leg is the loaded transaction, so only the counterpart needs preloading.
  belongs_to :inflow_transaction, class_name: "Transaction", inverse_of: :transfer_as_inflow
  belongs_to :outflow_transaction, class_name: "Transaction", inverse_of: :transfer_as_outflow

  # w2-transfers transfer-fees (decision 21): what the bank charged for the transfer, as
  # ordinary expenses in the 'Fees' category on the source or destination account. The
  # legs keep the principal. Deleting the transfer deletes its fees; rejecting it (these
  # two are not a transfer) keeps them as plain expenses. The foreign key clears the link
  # if a transfer row goes any other way.
  has_many :fee_transactions, class_name: "Transaction", foreign_key: :fee_transfer_id, inverse_of: :fee_transfer

  aasm column: :status, whiny_persistence: true do
    state :pending, initial: true
    state :confirmed

    # Runs inside the event's database transaction, so the status and the kinds change together
    event :confirm, after: :apply_transaction_kinds do
      transitions from: :pending, to: :confirmed
    end
  end

  # The kinds a leg takes from a transfer (apply_transaction_kinds)
  LEG_KINDS = (Transaction::TRANSFER_KINDS + %w[investment_contribution]).freeze

  # w2-transfers transfer-form-fixes: outflow kinds that budgets count as spending (a loan
  # payment, and an investment contribution under decision 29), so the transfer takes a
  # category. It lives on the outflow leg, the one budgets count.
  CATEGORIZABLE_KINDS = %w[loan_payment investment_contribution].freeze

  validates :inflow_transaction_id, uniqueness: true
  validates :outflow_transaction_id, uniqueness: true

  validate :transfer_has_different_accounts
  validate :transfer_has_same_family
  # These are the rules for pairing two transactions. They are checked when the pair is made;
  # a later edit to a leg (amount, date) is the user's call and must not make the transfer
  # impossible to confirm or annotate.
  validate :transfer_has_opposite_amounts, on: :create
  validate :transfer_within_date_range, on: :create

  after_create :apply_transaction_kinds, if: :confirmed?
  after_create :clear_rejection
  before_destroy :reset_transaction_kinds
  before_destroy :destroy_fee_entries
  after_destroy_commit :sync_fee_accounts_later

  FEE_SIDES = %w[source destination].freeze
  FEES_CATEGORY_NAME = "Fees" # the default expense category of the same name (Category.default_categories)

  class << self
    # The one rule for the kind of the outflow leg. Every way of making a transfer (Creator,
    # auto-match, manual match, rules) reaches it through apply_transaction_kinds, on create
    # when confirmed or on the confirm event.
    def outflow_kind_for(source_account:, destination_account:)
      # w3-reports exclude-from-reports: money to or from an account the reports leave out
      # is a plain movement, never spending (no loan payment, no contribution)
      if source_account.exclude_from_reports? || destination_account.exclude_from_reports?
        "funds_movement"
      elsif destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      elsif investment_like?(destination_account) && !investment_like?(source_account)
        "investment_contribution"
      else
        "funds_movement"
      end
    end

    # w3-reports exclude-from-reports: sets the kinds again on every confirmed transfer
    # with this account on one side, after its exclude_from_reports flag changed. Pending
    # transfers keep their legs' own kinds until confirmed, as always.
    def reapply_kinds_for!(account)
      account_transaction_ids = Transaction.joins(:entry).where(entries: { account_id: account.id }).select(:id)

      confirmed
        .where(outflow_transaction_id: account_transaction_ids)
        .or(confirmed.where(inflow_transaction_id: account_transaction_ids))
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
        .find_each(&:reapply_kinds!)
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
      release_fees!
      destroy!
    end
  end

  # --- Fees (w2-transfers transfer-fees) ---

  class << self
    # The family's 'Fees' expense category, created on first use
    def fees_category_for(family)
      family.categories.find_by(name: FEES_CATEGORY_NAME) ||
        family.categories.create!(name: FEES_CATEGORY_NAME, color: "#6b7280", lucide_icon: "receipt", classification: "expense")
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      family.categories.find_by!(name: FEES_CATEGORY_NAME)
    end
  end

  # The account a side's fee is charged to: the source (from) or the destination (to)
  def fee_account_for(side)
    case side.to_s
    when "source" then from_account
    when "destination" then to_account
    else raise ArgumentError, "unknown fee side #{side.inspect}"
    end
  end

  def fee_transactions_for(side)
    account = fee_account_for(side)
    return [] unless account && persisted?

    fee_transactions.includes(:entry).select { |txn| txn.entry&.account_id == account.id }.sort_by { |txn| txn.entry.created_at }
  end

  # The total fee on one side, in that account's currency, or nil when there is none
  def fee_money_for(side)
    fees = fee_transactions_for(side)
    return if fees.empty?

    fees.sum(Money.new(0, fee_account_for(side).currency)) { |txn| txn.entry.amount_money }
  end

  # Sets one side's fee to amount (in that account's currency). Blank or zero removes it;
  # an existing fee keeps its category and notes and takes the new amount. Returns true
  # when anything changed; the caller syncs the account.
  def set_fee!(side:, amount:)
    account = fee_account_for(side)
    amount = amount.presence && amount.to_d.abs
    fees = fee_transactions_for(side)

    changed = Transfer.transaction do
      if amount.nil? || amount.zero?
        fees.each { |txn| txn.entry.destroy! }
        fees.any?
      elsif (fee = fees.first)
        fee.entry.update!(amount: amount)
        fee.entry.saved_change_to_amount?
      else
        account.entries.create!(
          amount: amount,
          currency: account.currency,
          date: side.to_s == "source" ? outflow_transaction.entry.date : inflow_transaction.entry.date,
          name: I18n.t("transfer.fee_name", transfer: name),
          user_modified: true,
          entryable: Transaction.new(category: self.class.fees_category_for(family), fee_transfer: self)
        )
        true
      end
    end

    fee_transactions.reset
    changed
  end

  def family
    from_account&.family || to_account&.family
  end

  # Nil-safe: the new-transfer form asks an unsaved transfer for its date
  def date
    inflow_transaction&.entry&.date
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

  # Sets both legs' kinds again from the accounts (see reapply_kinds_for!)
  def reapply_kinds!
    apply_transaction_kinds if confirmed?
  end

  # Decided by the two accounts rather than the outflow's stored kind, so a pending match
  # (whose legs keep their own kinds until confirmed) answers the same as a confirmed one.
  def categorizable?
    return false unless from_account && to_account

    self.class.outflow_kind_for(source_account: from_account, destination_account: to_account).in?(CATEGORIZABLE_KINDS)
  end

  private
    # Rejecting keeps the fees as plain expenses: unlink them before the transfer goes, so
    # destroy_fee_entries finds none
    def release_fees!
      return unless persisted?

      Transaction.where(fee_transfer_id: id).update_all(fee_transfer_id: nil, updated_at: Time.current)
      fee_transactions.reset
    end

    def destroy_fee_entries
      entries = Entry.where(entryable_type: "Transaction", entryable_id: Transaction.where(fee_transfer_id: id).select(:id)).includes(:account).to_a
      @fee_accounts_to_sync = entries.map(&:account).uniq
      entries.each(&:destroy!)
    end

    def sync_fee_accounts_later
      Array(@fee_accounts_to_sync).each(&:sync_later)
    end

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

    # Sets the transfer kinds of the legs that survive this transfer back to standard. Another
    # kind (a one-time mark on a leg of a pending match) is the user's and stays. When the
    # transfer is destroyed because one of its legs is being destroyed, that leg is left alone.
    def reset_transaction_kinds
      surviving_legs.each do |txn|
        next unless txn.kind.in?(LEG_KINDS)

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
      return unless inflow_transaction&.entry&.date && outflow_transaction&.entry&.date

      date_diff = (inflow_transaction.entry.date - outflow_transaction.entry.date).abs
      max_days = confirmed? ? 30 : 4
      errors.add(:base, "Must be within #{max_days} days") if date_diff > max_days
    end
end
