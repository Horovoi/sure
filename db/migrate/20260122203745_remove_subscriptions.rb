class RemoveSubscriptions < ActiveRecord::Migration[7.2]
  def change
    drop_table :subscriptions do |t|
      t.uuid :family_id, null: false
      t.string :status, null: false
      t.string :stripe_id
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency
      t.string :interval
      t.datetime :current_period_ends_at
      t.datetime :trial_ends_at
      t.timestamps

      t.index :family_id, unique: true
    end

    remove_column :families, :stripe_customer_id, :string
  end
end
