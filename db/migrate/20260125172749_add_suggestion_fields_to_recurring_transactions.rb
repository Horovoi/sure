class AddSuggestionFieldsToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :suggestion_status, :string
    add_column :recurring_transactions, :dismissed_at, :datetime

    add_index :recurring_transactions, [ :family_id, :suggestion_status ],
              where: "suggestion_status = 'suggested'",
              name: "idx_suggested_subscriptions"
  end
end
