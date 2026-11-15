# Per-entry reconciliation mark (w3-toolstrx reconciliation-status, decision 26): a
# transaction is unreconciled until the user checks it against a statement, then
# cleared, then reconciled. A constant default makes the new column metadata-only on
# Postgres 11+, so existing rows are not rewritten.
class AddReconciledStatusToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :reconciled_status, :string, null: false, default: "unreconciled"
    add_check_constraint :entries,
      "reconciled_status IN ('unreconciled', 'cleared', 'reconciled')",
      name: "chk_entries_reconciled_status"
  end
end
