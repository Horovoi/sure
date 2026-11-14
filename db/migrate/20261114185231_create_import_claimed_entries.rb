# Records pre-existing entries that a TransactionImport matched as duplicates and
# took over, with the values the import overwrote, so reverting or deleting the
# import can hand them back instead of destroying them.
class CreateImportClaimedEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :import_claimed_entries, id: :uuid do |t|
      t.references :import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.uuid :previous_import_id
      t.uuid :previous_category_id
      t.uuid :previous_tag_ids, array: true, null: false, default: []
      t.text :previous_notes
      t.boolean :previous_import_locked, null: false, default: false

      t.timestamps
    end

    add_index :import_claimed_entries, %i[entry_id import_id], unique: true
  end
end
