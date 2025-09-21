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

    assert_equal ["Food & Drink", "Restaurants"], option_labels
    assert_equal [categories(:food_and_drink).id, categories(:subcategory).id], option_ids
  end
end
