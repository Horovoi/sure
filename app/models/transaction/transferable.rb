module Transaction::Transferable
  extend ActiveSupport::Concern

  included do
    has_one :transfer_as_inflow, class_name: "Transfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :transfer_as_outflow, class_name: "Transfer", foreign_key: "outflow_transaction_id", dependent: :destroy

    # We keep track of rejected transfers to avoid auto-matching them again
    has_one :rejected_transfer_as_inflow, class_name: "RejectedTransfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :rejected_transfer_as_outflow, class_name: "RejectedTransfer", foreign_key: "outflow_transaction_id", dependent: :destroy
  end

  def transfer
    transfer_as_inflow || transfer_as_outflow
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
