require "test_helper"

class Assistant::Function::CategoryToolsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @create = Assistant::Function::CreateCategory.new(@user)
    @update = Assistant::Function::UpdateCategory.new(@user)
  end

  test "create_category makes a top-level category with defaults" do
    result = nil
    assert_difference -> { @family.categories.count }, 1 do
      result = @create.call("name" => "Pets")
    end

    category = Category.find(result[:id])
    assert result[:created]
    assert_equal "Pets", category.name
    assert_equal "expense", category.classification
    assert_equal "layers", category.lucide_icon
    assert_match(/\A#\h{6}\z/, category.color)
  end

  test "create_category makes a subcategory that takes the parent's color and classification" do
    parent = categories(:income)
    parent.update!(classification: "income")

    result = @create.call("name" => "Bonus", "parent_id" => parent.id, "color" => "#000000", "classification" => "expense")

    category = Category.find(result[:id])
    assert_equal parent, category.parent
    assert_equal parent.color, category.color
    assert_equal "income", category.classification
  end

  test "create_category returns an existing name without changing it" do
    existing = categories(:food_and_drink)

    assert_no_difference -> { Category.count } do
      result = @create.call("name" => "Food & Drink", "color" => "#000000")
      assert_equal false, result[:created]
      assert_equal existing.id, result[:id]
    end
    assert_not_equal "#000000", existing.reload.color
  end

  test "create_category refuses a subcategory parent, bad colors and unknown icons" do
    assert_equal "parent_is_subcategory", @create.call("name" => "Deep", "parent_id" => categories(:subcategory).id)[:error]
    assert_equal "parent_not_found", @create.call("name" => "Lost", "parent_id" => categories(:one).id)[:error]
    assert_equal "invalid_color", @create.call("name" => "Red", "color" => "red")[:error]
    assert_equal "invalid_icon", @create.call("name" => "Odd", "icon" => "not-an-icon")[:error]
    assert_equal "invalid_classification", @create.call("name" => "Odd", "classification" => "transfer")[:error]
    assert_equal "invalid_name", @create.call("name" => " ")[:error]
  end

  test "update_category changes name, color and icon and audits the state before" do
    category = categories(:food_and_drink)
    before = @update.audit_before("id" => category.id)

    result = @update.call("id" => category.id, "name" => "Dining", "color" => "#123456", "icon" => "pizza")

    assert result[:updated]
    category.reload
    assert_equal [ "Dining", "#123456", "pizza" ], [ category.name, category.color, category.lucide_icon ]
    assert_equal "Food & Drink", before[:name]
    assert_equal "utensils", before[:icon]
  end

  test "update_category is an idempotent write" do
    assert_equal :write, @update.scope_tag
    assert @update.idempotent?
  end

  test "update_category refuses another family's category, empty calls and duplicates" do
    assert_equal "not_found", @update.call("id" => categories(:one).id, "name" => "Mine")[:error]
    assert_equal "no_changes", @update.call("id" => categories(:food_and_drink).id)[:error]
    assert_raises(ActiveRecord::RecordInvalid) { @update.call("id" => categories(:food_and_drink).id, "name" => "Income") }
  end
end
