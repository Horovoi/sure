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

  test "merge page lists the family's categories with parents before their subcategories" do
    get merge_categories_url
    assert_response :success

    body = response.body
    assert_includes body, categories(:food_and_drink).id
    assert_not_includes body, categories(:one).id
    assert_operator body.index(%(value="#{categories(:food_and_drink).id}")), :<, body.index(%(value="#{categories(:subcategory).id}"))
  end

  test "index links to the merge page" do
    get categories_url
    assert_select "a[href='#{merge_categories_path}']"
  end

  test "perform_merge moves transactions and deletes the sources" do
    target = categories(:food_and_drink)
    source = families(:dylan_family).categories.create!(name: "Eating out", color: "#000000", lucide_icon: "utensils", classification: target.classification)
    @transaction.update!(category: source)

    assert_difference "Category.count", -1 do
      post merge_categories_url, params: { category_merge: { category_id: target.id, source_ids: [ source.id ] } }
    end

    assert_redirected_to categories_url
    assert_equal target, @transaction.reload.category
    assert_match target.name, flash[:notice]
  end

  test "perform_merge refuses to merge across classifications" do
    target = categories(:food_and_drink)
    income = families(:dylan_family).categories.create!(name: "Salary", color: "#000000", lucide_icon: "banknote", classification: "income")

    assert_no_difference "Category.count" do
      post merge_categories_url, params: { category_merge: { category_id: target.id, source_ids: [ income.id ] } }
    end

    assert_redirected_to merge_categories_url
    assert_match "Salary", flash[:alert]
  end

  test "perform_merge ignores another family's categories" do
    target = categories(:food_and_drink)

    assert_no_difference "Category.count" do
      post merge_categories_url, params: { category_merge: { category_id: target.id, source_ids: [ categories(:one).id ] } }
    end

    assert_redirected_to merge_categories_url
    assert Category.exists?(categories(:one).id)
  end

  test "perform_merge needs a target in the family" do
    assert_no_difference "Category.count" do
      post merge_categories_url, params: { category_merge: { category_id: categories(:one).id, source_ids: [ categories(:food_and_drink).id ] } }
    end

    assert_redirected_to merge_categories_url
  end

  test "perform_merge with only the target selected merges nothing" do
    target = categories(:food_and_drink)

    assert_no_difference "Category.count" do
      post merge_categories_url, params: { category_merge: { category_id: target.id, source_ids: [ target.id ] } }
    end

    assert_redirected_to merge_categories_url
  end
end
