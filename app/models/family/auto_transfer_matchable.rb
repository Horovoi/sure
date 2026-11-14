module Family::AutoTransferMatchable
  def transfer_match_candidates(date_window: 4)
    Entry.select([
      "inflow_candidates.entryable_id as inflow_transaction_id",
      "outflow_candidates.entryable_id as outflow_transaction_id",
      "ABS(inflow_candidates.date - outflow_candidates.date) as date_diff"
    ]).from("entries inflow_candidates")
      .joins("
        JOIN entries outflow_candidates ON (
          inflow_candidates.amount < 0 AND
          outflow_candidates.amount > 0 AND
          inflow_candidates.account_id <> outflow_candidates.account_id AND
          inflow_candidates.date BETWEEN outflow_candidates.date - #{date_window.to_i} AND outflow_candidates.date + #{date_window.to_i}
        )
      ").joins("
        LEFT JOIN transfers existing_transfers ON (
          existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
          existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
        )
      ")
      .joins("LEFT JOIN rejected_transfers ON (
        rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
        rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
      )")
      .joins("LEFT JOIN exchange_rates ON (
        exchange_rates.date = outflow_candidates.date AND
        exchange_rates.from_currency = outflow_candidates.currency AND
        exchange_rates.to_currency = inflow_candidates.currency
      )")
      .joins("JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id")
      .joins("JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id")
      .where("inflow_accounts.family_id = ? AND outflow_accounts.family_id = ?", self.id, self.id)
      .where(Account.visible_status_sql("inflow_accounts"))
      .where(Account.visible_status_sql("outflow_accounts"))
      .where("inflow_candidates.entryable_type = 'Transaction' AND outflow_candidates.entryable_type = 'Transaction'")
      .where("
        (
          inflow_candidates.currency = outflow_candidates.currency AND
          inflow_candidates.amount = -outflow_candidates.amount
        ) OR (
          inflow_candidates.currency <> outflow_candidates.currency AND
          ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * exchange_rates.rate, 0)) BETWEEN 0.95 AND 1.05
        )
      ")
      .where(existing_transfers: { id: nil })
      .order("date_diff ASC") # Closest matches first
  end

  # Pairs unmatched transactions as pending transfers.
  #
  # Runs after every account sync and after the family sync, so several runs can overlap.
  # A family-level advisory lock serializes them (and Transfer#reject!), and each pair is created
  # in its own savepoint, so a pair that loses a race is skipped without aborting the run.
  def auto_match_transfers!
    Transfer.transaction do
      lock_transfer_matching!

      used_transaction_ids = Set.new

      auto_match_candidates.each do |match|
        next if used_transaction_ids.include?(match.inflow_transaction_id) ||
               used_transaction_ids.include?(match.outflow_transaction_id)

        if create_auto_matched_transfer(match)
          used_transaction_ids << match.inflow_transaction_id
          used_transaction_ids << match.outflow_transaction_id
        end
      end
    end
  end

  # Serializes auto-matching and rejecting transfers for this family until the current
  # database transaction ends.
  def lock_transfer_matching!
    raise "lock_transfer_matching! must run inside a transaction" unless self.class.connection.transaction_open?

    self.class.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "auto_match_transfers:#{id}" ])
    )
  end

  private
    # Only plain transactions are auto-matched: not excluded, not pending at the provider, and
    # still "standard" (a user's one-time mark, or any other kind, is left alone).
    def auto_match_candidates
      transfer_match_candidates
        .joins("JOIN transactions inflow_txns ON inflow_txns.id = inflow_candidates.entryable_id")
        .joins("JOIN transactions outflow_txns ON outflow_txns.id = outflow_candidates.entryable_id")
        .where(rejected_transfers: { id: nil })
        .where(inflow_candidates: { excluded: false }, outflow_candidates: { excluded: false })
        .where(inflow_txns: { kind: "standard" }, outflow_txns: { kind: "standard" })
        .where("NOT #{pending_condition('inflow_txns')} AND NOT #{pending_condition('outflow_txns')}")
    end

    def pending_condition(table)
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(#{table}.extra) = 'object' THEN #{table}.extra ELSE '{}'::jsonb END) AS pd
          WHERE jsonb_typeof(pd.value) = 'object' AND (pd.value ->> 'pending')::boolean = true
        )
      SQL
    end

    def create_auto_matched_transfer(match)
      Transfer.transaction(requires_new: true) do
        Transfer.create!(
          inflow_transaction_id: match.inflow_transaction_id,
          outflow_transaction_id: match.outflow_transaction_id
        )
      end
      true
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.info("Skipped auto-matching transfer #{match.outflow_transaction_id} -> #{match.inflow_transaction_id}: #{e.message}")
      false
    end
end
