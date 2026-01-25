class AddDefaultAccountToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_reference :recurring_transactions, :default_account, type: :uuid,
                  foreign_key: { to_table: :accounts }, null: true
  end
end
