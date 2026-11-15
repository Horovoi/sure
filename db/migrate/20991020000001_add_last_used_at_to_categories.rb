# The category pickers show the categories a family picked by hand most
# recently above the alphabetical list. last_used_at records that pick; it is
# only written from the manual assignment paths (Transaction#record_category_usage!),
# never by rules or imports. A NULL means "not picked by hand yet".
class AddLastUsedAtToCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :categories, :last_used_at, :datetime
    add_index :categories, [ :family_id, :last_used_at ]
  end
end
