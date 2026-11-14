# A transaction can be a leg of only one transfer. The app checked this, but two concurrent
# auto-match runs could still create (A,B) and (A,C). This removes any such duplicates (keeping
# a confirmed transfer over a pending one, then the oldest) and enforces it in the database.
#
# It also lets a transaction delete remove its rejected-transfer rows, as it already does for
# transfers.
class AddUniqueTransferLegIndexes < ActiveRecord::Migration[7.2]
  def up
    %w[inflow_transaction_id outflow_transaction_id].each do |column|
      execute <<~SQL
        DELETE FROM transfers
        WHERE id IN (
          SELECT id FROM (
            SELECT id, ROW_NUMBER() OVER (
              PARTITION BY #{column}
              ORDER BY (status = 'confirmed') DESC, created_at ASC, id ASC
            ) AS position
            FROM transfers
          ) ranked
          WHERE ranked.position > 1
        )
      SQL

      remove_index :transfers, column
      add_index :transfers, column, unique: true
    end

    remove_foreign_key :rejected_transfers, :transactions, column: :inflow_transaction_id
    remove_foreign_key :rejected_transfers, :transactions, column: :outflow_transaction_id

    # Data loaded with triggers off (a restore) can hold rejections whose transactions are
    # gone, although the old constraint is marked valid. They can never be read; drop them
    # so the new constraint validates.
    execute <<~SQL
      DELETE FROM rejected_transfers r
      WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.id = r.inflow_transaction_id)
         OR NOT EXISTS (SELECT 1 FROM transactions t WHERE t.id = r.outflow_transaction_id)
    SQL

    add_foreign_key :rejected_transfers, :transactions, column: :inflow_transaction_id, on_delete: :cascade
    add_foreign_key :rejected_transfers, :transactions, column: :outflow_transaction_id, on_delete: :cascade
  end

  def down
    remove_foreign_key :rejected_transfers, :transactions, column: :inflow_transaction_id
    remove_foreign_key :rejected_transfers, :transactions, column: :outflow_transaction_id
    add_foreign_key :rejected_transfers, :transactions, column: :inflow_transaction_id
    add_foreign_key :rejected_transfers, :transactions, column: :outflow_transaction_id

    %w[inflow_transaction_id outflow_transaction_id].each do |column|
      remove_index :transfers, column
      add_index :transfers, column
    end
  end
end
