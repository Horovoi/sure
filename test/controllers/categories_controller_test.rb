require "test_helper"

class CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @transaction = transactions :one
  end

  test "index" do
    get categories_url
    assert_response :success
  end

  test "new" do
    get new_category_url
    assert_response :success
  end

  test "create" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
  end

  test "create fails if name is not unique" do
    assert_no_difference "Category.count" do
      post categories_url, params: {
        category: {
          name: categories(:food_and_drink).name,
          color: Category::COLORS.sample } }
    end

    assert_response :unprocessable_entity
  end

  test "create and assign to transaction" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        transaction_id: @transaction.id,
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
    assert_equal @transaction.reload.category, new_category
  end

  test "edit" do
    get edit_category_url(categories(:food_and_drink))
    assert_response :success
  end

  test "update" do
    new_color = Category::COLORS.without(categories(:income).color).sample

    assert_changes -> { categories(:income).name }, to: "New Name" do
      assert_changes -> { categories(:income).reload.color }, to: new_color do
        patch category_url(categories(:income)), params: {
          category: {
            name: "New Name",
            color: new_color } }
      end
    end

    assert_redirected_to categories_url
  end

  test "bootstrap" do
    # 22 default categories minus 3 that already exist in fixtures (Income, Food & Drink, Subscriptions)
    assert_difference "Category.count", 19 do
      post bootstrap_categories_url
    end

    assert_redirected_to categories_url
  end

  # --- DS pickers: inline create through the JSON endpoint ---

  test "JSON create keeps the classification the picker sends and returns the option markup" do
    assert_difference "Category.count", +1 do
      post categories_url(format: :json), params: {
        category: { name: "Freelance", color: Category::COLORS.first, classification: "income" }
      }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    category = Category.find(body["id"])
    assert_equal "income", category.classification
    assert_equal "income", body["classification"]
    assert_includes body["html"], %(data-category-id="#{category.id}")
    assert_includes body["html"], "Freelance"
  end

  test "JSON create of a subcategory takes the parent's classification, not the form's" do
    parent = users(:family_admin).family.categories.create!(
      name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase"
    )

    post categories_url(format: :json), params: {
      category: { name: "Overtime", color: Category::COLORS.first, classification: "expense", parent_id: parent.id }
    }, as: :json

    assert_response :created
    category = Category.find(response.parsed_body["id"])
    assert_equal parent, category.parent
    assert_equal "income", category.classification
  end

  test "JSON create returns the validation errors" do
    existing = categories(:food_and_drink)

    assert_no_difference "Category.count" do
      post categories_url(format: :json), params: {
        category: { name: existing.name, color: Category::COLORS.first, classification: "expense" }
      }, as: :json
    end

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any?
  end

  test "JSON create rejects a parent from another family" do
    foreign_parent = categories(:one)

    assert_no_difference "Category.count" do
      post categories_url(format: :json), params: {
        category: { name: "Sneaky", color: Category::COLORS.first, classification: "expense", parent_id: foreign_parent.id }
      }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "create with a transaction assigns it and records the category as recently used" do
    post categories_url, params: {
      transaction_id: @transaction.id,
      category: { name: "Picked", color: Category::COLORS.first, classification: "expense", lucide_icon: "layers" }
    }

    category = Category.find_by!(name: "Picked")
    assert_equal category, @transaction.reload.category
    assert_not_nil category.last_used_at
  end
end
