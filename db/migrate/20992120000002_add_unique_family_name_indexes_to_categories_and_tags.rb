# Category and tag names are unique per family. The models validate it, but two
# concurrent creates (an import and an inline create, or a double click) can
# both pass the check. A unique index makes the database refuse the second one.
#
# Existing duplicates are not merged here: a merge deletes rows. When any exist,
# the migration stops and lists them. Merge them first (Settings > Categories >
# Merge categories, or Tag#replace_and_destroy!), then run it again.
#
# The check is exact, like the validation: "Food" and "food" are two names.
class AddUniqueFamilyNameIndexesToCategoriesAndTags < ActiveRecord::Migration[8.1]
  TABLES = %w[categories tags].freeze

  def up
    duplicates = TABLES.flat_map { |table| duplicate_names(table) }

    if duplicates.any?
      raise <<~MESSAGE
        Duplicate names block the unique [family_id, name] indexes. Merge these first, then migrate again:
        #{duplicates.map { |row| "  #{row["table_name"]}: family #{row["family_id"]}, #{row["name"].inspect} x#{row["copies"]}" }.join("\n")}
      MESSAGE
    end

    TABLES.each do |table|
      add_index table, %i[family_id name], unique: true, name: "index_#{table}_on_family_id_and_name"
    end
  end

  def down
    TABLES.each do |table|
      remove_index table, name: "index_#{table}_on_family_id_and_name", if_exists: true
    end
  end

  private
    def duplicate_names(table)
      select_all(<<~SQL.squish).to_a
        SELECT '#{table}' AS table_name, family_id, name, COUNT(*) AS copies
        FROM #{quote_table_name(table)}
        WHERE name IS NOT NULL
        GROUP BY family_id, name
        HAVING COUNT(*) > 1
        ORDER BY family_id, name
      SQL
    end
end
