require "test_helper"
# The stamp changes when the migration is re-stamped, so find it by name.
require Dir[Rails.root.join("db/migrate/*_add_unique_family_name_indexes_to_categories_and_tags.rb")].first

class AddUniqueFamilyNameIndexesTest < ActiveSupport::TestCase
  setup do
    @connection = ActiveRecord::Base.connection
    # Postgres DDL is transactional: the test's rollback puts the indexes back.
    %w[categories tags].each do |table|
      @connection.remove_index table, name: "index_#{table}_on_family_id_and_name", if_exists: true
    end
  end

  test "adds the unique indexes when no names repeat" do
    migrate

    %w[categories tags].each do |table|
      index = @connection.indexes(table).find { |i| i.name == "index_#{table}_on_family_id_and_name" }
      assert index&.unique, "#{table} has no unique [family_id, name] index"
    end
  end

  test "stops and lists the duplicates instead of merging them" do
    family = families(:dylan_family)
    Category.insert_all!([ { family_id: family.id, name: "Food & Drink", color: "#000000", lucide_icon: "utensils", classification: "expense" } ])
    Tag.insert_all!([ { family_id: family.id, name: tags(:one).name, color: "#000000" } ])

    error = assert_raises(StandardError) { migrate }

    assert_includes error.message, %("Food & Drink")
    assert_includes error.message, "tags: family #{family.id}"
    assert_equal 2, family.categories.where(name: "Food & Drink").count
    assert_not @connection.index_name_exists?(:categories, "index_categories_on_family_id_and_name")
  end

  private
    def migrate
      ActiveRecord::Migration.suppress_messages do
        AddUniqueFamilyNameIndexesToCategoriesAndTags.new.migrate(:up)
      end
    end
end
