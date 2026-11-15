module Transaction::Transferable
  extend ActiveSupport::Concern

  included do
    # inverse_of is load-bearing: Transfer#categorizable? reads both legs' accounts on every
    # transfer row, and the inverse makes the row's own leg the already-loaded transaction
    # (ROW_ASSOCIATIONS preloads only the counterpart).
    has_one :transfer_as_inflow, class_name: "Transfer", foreign_key: "inflow_transaction_id", inverse_of: :inflow_transaction, dependent: :destroy
    has_one :transfer_as_outflow, class_name: "Transfer", foreign_key: "outflow_transaction_id", inverse_of: :outflow_transaction, dependent: :destroy

    # We keep track of rejected transfers to avoid auto-matching them again
    has_one :rejected_transfer_as_inflow, class_name: "RejectedTransfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :rejected_transfer_as_outflow, class_name: "RejectedTransfer", foreign_key: "outflow_transaction_id", dependent: :destroy
  end

  def transfer
    transfer_as_inflow || transfer_as_outflow
  end

  # --- Category ownership (w2-transfers transfer-form-fixes) ---

  # Whether the user picks this transaction's category. A transaction outside a transfer,
  # or a leg of a pending match (it keeps its own kind and still counts as income or
  # spending), always can. In a confirmed transfer the category belongs to the outflow leg,
  # the one budgets count, and only when the transfer is categorizable (a loan payment or an
  # investment contribution); the other transfers show the Transfer or Payment badge.
  def category_editable?
    return false if category_set_on_transfer_outflow?

    matched = transfer
    return true if matched.nil? || !matched.confirmed?

    matched.categorizable? && matched.outflow_transaction_id == id
  end

  # The inflow leg of a confirmed, categorizable transfer: it shows the outflow's category
  # read-only. A category picked here would look saved but never reach a budget. Decided by
  # the Transfer record, not this leg's kind.
  def category_set_on_transfer_outflow?
    matched = transfer_as_inflow
    matched.present? && matched.confirmed? && matched.categorizable?
  end

  # Whether a non-editable leg shows the Payment badge instead of Transfer. The transfer
  # decides when there is one; a leg without one falls back to its own kind.
  def payment?
    matched = transfer
    matched ? matched.payment? : kind == "cc_payment"
  end

  def transfer_match_candidates(date_window: 30)
    candidates_scope = if self.entry.amount.negative?
      family_matches_scope(date_window: date_window).where("inflow_candidates.entryable_id = ?", self.id)
    else
      family_matches_scope(date_window: date_window).where("outflow_candidates.entryable_id = ?", self.id)
    end

    candidates = candidates_scope.map do |match|
      Transfer.new(
        inflow_transaction_id: match.inflow_transaction_id,
        outflow_transaction_id: match.outflow_transaction_id,
      )
    end

    likeliest_first(candidates)
  end

  private
    # A pair the user already rejected goes last, and a counterpart in this transaction's
    # category goes first (the dialog preselects it), so the dialog a "Transfer?" hint opens
    # defaults to the pair the hint found. Otherwise the query's order stays (exact amounts,
    # then the nearest date).
    def likeliest_first(candidates)
      return candidates if candidates.size < 2

      counterpart_id = ->(candidate) { candidate.inflow_transaction_id == id ? candidate.outflow_transaction_id : candidate.inflow_transaction_id }
      category_ids = Transaction.where(id: candidates.map(&counterpart_id)).pluck(:id, :category_id).to_h
      rejected_ids = RejectedTransfer.where(inflow_transaction_id: id).pluck(:outflow_transaction_id) +
        RejectedTransfer.where(outflow_transaction_id: id).pluck(:inflow_transaction_id)

      candidates.each_with_index.sort_by do |candidate, index|
        counterpart = counterpart_id.call(candidate)
        [ rejected_ids.include?(counterpart) ? 1 : 0, category_ids[counterpart] == category_id ? 0 : 1, index ]
      end.map(&:first)
    end

    def family_matches_scope(date_window:)
      self.entry.account.family.transfer_match_candidates(date_window: date_window)
    end
end
