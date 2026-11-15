# A family's choice of category for one merchant-code group (Mcc::Taxonomy). Bank
# connections that report an MCC (monobank today) use it to categorise new transactions.
# A family with no row for a group gets the automatic match (Mcc::DefaultMapping);
# a row overrides it: disabled = "don't categorise", else the chosen category.
# Deleting the category nullifies category_id, so the group falls back to automatic.
class CreateMccCategoryMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :mcc_category_mappings, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      # Mcc::Taxonomy group key, e.g. "groceries"
      t.string :group_key, null: false
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid
      t.boolean :disabled, null: false, default: false

      t.timestamps
    end

    add_index :mcc_category_mappings, [ :family_id, :group_key ], unique: true
  end
end
