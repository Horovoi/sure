class AddSubscriptionServiceToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_reference :recurring_transactions, :subscription_service, foreign_key: true, type: :uuid
  end
end
