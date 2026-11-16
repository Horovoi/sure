# A split transaction keeps its own entry (the parent, which still drives the account
# balance) and gets one child entry per part. Children point at the parent; deleting the
# parent deletes them (Entry#split! and Entry#unsplit! are the only writers).
class AddParentEntryIdToEntries < ActiveRecord::Migration[8.1]
  def change
    add_reference :entries, :parent_entry, type: :uuid, null: true,
      foreign_key: { to_table: :entries, on_delete: :cascade },
      index: { where: "parent_entry_id IS NOT NULL" }
  end
end
