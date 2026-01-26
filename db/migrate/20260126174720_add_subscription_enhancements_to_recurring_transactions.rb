class AddSubscriptionEnhancementsToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    # Enhancement 1: Auto-infer account
    add_reference :recurring_transactions, :inferred_account, type: :uuid, foreign_key: { to_table: :accounts }

    # Enhancement 2: USD base currency detection
    add_column :recurring_transactions, :detected_base_currency, :string
    add_column :recurring_transactions, :detected_base_amount, :decimal, precision: 19, scale: 4

    # Enhancement 3: Expected month for yearly subscriptions
    add_column :recurring_transactions, :expected_month, :integer
    add_check_constraint :recurring_transactions, "expected_month IS NULL OR (expected_month >= 1 AND expected_month <= 12)", name: "check_expected_month_range"

    # Backfill expected_month for existing yearly subscriptions
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE recurring_transactions
          SET expected_month = EXTRACT(MONTH FROM next_expected_date)::integer
          WHERE is_subscription = true
            AND billing_cycle = 'yearly'
            AND next_expected_date IS NOT NULL
        SQL
      end
    end
  end
end
