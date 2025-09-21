require "test_helper"
require "ostruct"

class CategoriesHelperTest < ActionView::TestCase
  include CategoriesHelper

  def setup
    @user = users(:family_admin)
    Current.session = OpenStruct.new(user: @user)
  end

  def teardown
    Current.session = nil
  end

  test "grouped family categories returns parents with nested subcategories" do
    groups = grouped_family_categories

    food_group = groups.find { |group| group.category.name == "Food & Drink" }
    assert food_group, "expected Food & Drink group to be present"

    assert_equal ["Restaurants"], food_group.subcategories.map(&:name)
  end
end
