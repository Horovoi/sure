# w2-transfers default-account: the account the new-transaction and new-transfer forms
# preselect. Deleting the account clears it in the database; the app clears it when the
# account is disabled or queued for deletion.
class AddDefaultAccountToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :default_account,
      type: :uuid,
      null: true,
      index: true,
      foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
