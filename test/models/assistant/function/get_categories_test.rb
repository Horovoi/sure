require "test_helper"

class Assistant::Function::GetCategoriesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetCategories.new(@user)
  end

  test "has correct name and is not strict" do
    assert_equal "get_categories", @fn.name
    refute @fn.to_definition[:strict], "optional params need strict mode off"
  end

  test "lists the family's categories with hierarchy fields" do
    result = @fn.call
    rows = result[:categories].index_by { |c| c[:id] }

    assert_equal @user.family.categories.count, result[:total_results]

    child = rows[categories(:subcategory).id]
    assert_equal categories(:subcategory).parent_id, child[:parent_id]
    assert_equal true, child[:is_subcategory]
    assert_match " > ", child[:name_with_parent]

    parent = rows[categories(:food_and_drink).id]
    assert_not parent.key?(:parent_id)
    assert parent[:icon].present?
  end

  test "pages with page_size" do
    result = @fn.call("page_size" => 2, "page" => 1)

    assert_equal 2, result[:categories].size
    assert_equal 2, result[:page_size]
    assert_operator result[:total_pages], :>=, 2
  end

  test "an invalid page reads as the first page" do
    assert_equal 1, @fn.call("page" => 0)[:page]
  end

  test "does not list another family's categories" do
    other = users(:empty).family.categories.create!(name: "Other family only", color: "#123456", lucide_icon: "circle")

    assert_not_includes @fn.call("page_size" => 100)[:categories].map { |c| c[:id] }, other.id
  end
end
