# One-time data fix for transactions.kind, which is a stored copy of "this transaction is a leg
# of a Transfer" (Transfer is now its only writer):
#
# 1. A transfer kind with no Transfer row (left behind when one leg of a transfer was deleted,
#    or by the de-duplication in AddUniqueTransferLegIndexes) goes back to standard.
# 2. Inflow legs are funds_movement.
# 3. Outflow legs get the kind from Transfer.outflow_kind_for, which auto-match and manual match
#    used to get wrong (they looked at the source account instead of the destination).
#
# Touched entries get a new updated_at so cached report totals are recomputed. Idempotent.
class FixTransferKinds < ActiveRecord::Migration[7.2]
  TRANSFER_KINDS = "('funds_movement', 'cc_payment', 'loan_payment', 'investment_contribution')".freeze

  def up
    changed_ids = []

    changed_ids += select_values(<<~SQL)
      UPDATE transactions SET kind = 'standard', updated_at = NOW()
      WHERE kind IN #{TRANSFER_KINDS}
        AND NOT EXISTS (
          SELECT 1 FROM transfers
          WHERE transfers.inflow_transaction_id = transactions.id
             OR transfers.outflow_transaction_id = transactions.id
        )
      RETURNING id
    SQL

    changed_ids += select_values(<<~SQL)
      UPDATE transactions SET kind = 'funds_movement', updated_at = NOW()
      FROM transfers
      WHERE transfers.inflow_transaction_id = transactions.id
        AND transactions.kind <> 'funds_movement'
      RETURNING transactions.id
    SQL

    changed_ids += select_values(<<~SQL)
      UPDATE transactions SET kind = expected.kind, updated_at = NOW()
      FROM (
        SELECT transfers.outflow_transaction_id AS transaction_id,
          CASE
            WHEN destination.accountable_type = 'Loan' THEN 'loan_payment'
            WHEN destination.classification = 'liability' THEN 'cc_payment'
            WHEN destination.accountable_type IN ('Investment', 'Crypto')
              AND source.accountable_type NOT IN ('Investment', 'Crypto') THEN 'investment_contribution'
            ELSE 'funds_movement'
          END AS kind
        FROM transfers
        JOIN entries inflow_entries ON inflow_entries.entryable_type = 'Transaction' AND inflow_entries.entryable_id = transfers.inflow_transaction_id
        JOIN entries outflow_entries ON outflow_entries.entryable_type = 'Transaction' AND outflow_entries.entryable_id = transfers.outflow_transaction_id
        JOIN accounts destination ON destination.id = inflow_entries.account_id
        JOIN accounts source ON source.id = outflow_entries.account_id
      ) expected
      WHERE transactions.id = expected.transaction_id
        AND transactions.kind <> expected.kind
      RETURNING transactions.id
    SQL

    changed_ids.uniq.each_slice(1000) do |ids|
      execute <<~SQL
        UPDATE entries SET updated_at = NOW()
        WHERE entryable_type = 'Transaction' AND entryable_id IN (#{ids.map { |id| connection.quote(id) }.join(', ')})
      SQL
    end

    say "Fixed the kind of #{changed_ids.uniq.size} transaction(s)"
  end

  def down
    # Data fix only; the previous kinds were wrong and are not kept.
  end
end
