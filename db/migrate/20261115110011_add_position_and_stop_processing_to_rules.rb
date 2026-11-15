# Rules run top to bottom in a family (Rule::Runner). Existing rules are numbered
# in the order the rules page showed them by default (name A-Z, unnamed last), so
# the first ordered run matches the list the user already sees.
class AddPositionAndStopProcessingToRules < ActiveRecord::Migration[8.1]
  def up
    add_column :rules, :position, :integer, null: false, default: 0
    add_column :rules, :stop_processing, :boolean, null: false, default: false
    add_index :rules, [ :family_id, :position ]

    execute <<~SQL.squish
      UPDATE rules SET position = ranked.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY family_id ORDER BY LOWER(name) ASC NULLS LAST, created_at, id
        ) AS rn
        FROM rules
      ) ranked
      WHERE rules.id = ranked.id
    SQL
  end

  def down
    remove_index :rules, [ :family_id, :position ]
    remove_column :rules, :stop_processing
    remove_column :rules, :position
  end
end
