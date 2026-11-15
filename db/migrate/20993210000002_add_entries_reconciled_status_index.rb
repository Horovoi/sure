# For the account header's reconciliation counts and the reconciliation filter
# (w3-toolstrx reconciliation-status). Built concurrently so writes to entries go on.
class AddEntriesReconciledStatusIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :entries, %i[account_id reconciled_status],
      name: "index_entries_on_account_id_and_reconciled_status",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
