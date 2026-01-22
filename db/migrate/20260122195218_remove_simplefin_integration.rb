class RemoveSimplefinIntegration < ActiveRecord::Migration[7.2]
  def up
    # Clean up account_providers polymorphic records
    execute "DELETE FROM account_providers WHERE provider_type = 'SimplefinAccount'"

    # Remove foreign key column from accounts
    remove_column :accounts, :simplefin_account_id, :uuid

    # Drop SimpleFIN tables
    drop_table :simplefin_accounts
    drop_table :simplefin_items
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
