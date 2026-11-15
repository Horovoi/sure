require "test_helper"

class Category::DeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @category = categories(:food_and_drink)
  end

  test "new" do
    get new_category_deletion_url(@category)
    assert_response :success
  end

  test "create with replacement" do
    replacement_category = categories(:income)

    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "replacement_category.transactions.count", @category.transactions.count do
        post category_deletions_url(@category),
          params: { replacement_category_id: replacement_category.id }
      end
    end

    assert_redirected_to transactions_url
  end

  test "create without replacement" do
    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "Transaction.where(category: nil).count", @category.transactions.count do
        post category_deletions_url(@category)
      end
    end

    assert_redirected_to transactions_url
  end

  test "create from the deletion page opened on its own goes to the categories" do
    post category_deletions_url(@category), headers: { "Referer" => new_category_deletion_url(@category) }

    assert_redirected_to categories_url
  end

  test "create goes back to the page the deletion was opened from" do
    post category_deletions_url(@category), headers: { "Referer" => categories_url }

    assert_redirected_to categories_url
    assert_equal I18n.t("category.deletions.create.success"), flash[:notice]
  end
end
