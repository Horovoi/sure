class AddSubscriptionFieldsToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :is_subscription, :boolean, default: false, null: false
    add_column :recurring_transactions, :billing_cycle, :string, default: "monthly"
    add_column :recurring_transactions, :category_id, :uuid
    add_column :recurring_transactions, :notes, :text
    add_column :recurring_transactions, :custom_logo_url, :string

    add_index :recurring_transactions, [ :family_id, :is_subscription ],
              where: "is_subscription = true",
              name: "idx_recurring_txns_subscriptions"

    add_foreign_key :recurring_transactions, :categories
  end
end
