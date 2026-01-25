class AddRecurringTransactionToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_reference :transactions, :recurring_transaction, type: :uuid,
                  foreign_key: true, index: true, null: true
  end
end
