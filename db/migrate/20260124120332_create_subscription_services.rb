class CreateSubscriptionServices < ActiveRecord::Migration[7.2]
  def change
    create_table :subscription_services, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :domain, null: false
      t.string :category
      t.string :color

      t.timestamps
    end

    add_index :subscription_services, :slug, unique: true
    add_index :subscription_services, :name
    add_index :subscription_services, :category
  end
end
