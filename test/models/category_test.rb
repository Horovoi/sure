require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "grouped select options include parent and subcategories" do
    options = Category.grouped_select_options(
      @family.categories.includes(:subcategories).roots.alphabetically
    )

    food_group = options.find { |label, _| label == "Food & Drink" }
    assert food_group, "expected Food & Drink group to be present"

    option_labels = food_group.last.map(&:first)
    option_ids = food_group.last.map(&:second)

    assert_equal [ "Food & Drink", "Restaurants" ], option_labels
    assert_equal [ categories(:food_and_drink).id, categories(:subcategory).id ], option_ids
  end

  test "accepts six-digit hex colors" do
    [ "#FFFFFF", "#000000", "#123456", "#ABCDEF", "#abcdef" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert category.valid?, "#{color} should be valid"
    end
  end

  test "rejects a color that is not six-digit hex" do
    [ "invalid", "#123", "#1234567", "#GGGGGG", "red", "ffffff", "#ffff" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert_not category.valid?, "#{color} should be invalid"
      assert category.errors.of_kind?(:color, :invalid)
    end
  end

  test "an existing category with an old non-hex color still saves other fields" do
    category = categories(:income)
    category.update_column(:color, "#abc")

    assert category.update(name: "Renamed income")
    assert_not category.update(color: "#abcd"), "changing to a bad color is still rejected"
  end

  test "changing a parent's color updates its subcategories" do
    parent = categories(:food_and_drink)
    subcategory = categories(:subcategory)
    previous_updated_at = subcategory.updated_at

    travel 1.second do
      parent.update!(color: "#123456")
    end

    subcategory.reload
    assert_equal "#123456", subcategory.color
    assert_operator subcategory.updated_at, :>, previous_updated_at
  end
end
