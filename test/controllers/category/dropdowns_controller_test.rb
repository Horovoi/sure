require "test_helper"

class Category::DropdownsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @transaction = transactions(:one)
  end

  test "shows the recently used categories above the list" do
    recent = categories(:subscriptions)
    recent.update!(last_used_at: 1.minute.ago)

    get category_dropdown_url(category_id: @transaction.category_id, transaction_id: @transaction.id)

    assert_response :success
    assert_select "[data-list-filter-target=recentSection] [data-filter-name='#{recent.name}']"
  end

  test "the selected category is not repeated under Recent" do
    @transaction.category.update!(last_used_at: 1.minute.ago)

    get category_dropdown_url(category_id: @transaction.category_id, transaction_id: @transaction.id)

    assert_select "[data-list-filter-target=recentSection]", count: 0
  end

  test "an inline create gets the transaction's nature and offers only parents of it" do
    @transaction.entry.update!(amount: -50)
    income_parent = @user.family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")

    get category_dropdown_url(transaction_id: @transaction.id)

    assert_select "[data-category-quick-create-classification-value=income]"
    assert_select "[data-action='category-quick-create#createUnderParent'][data-parent-id='#{income_parent.id}']"
    assert_select "[data-action='category-quick-create#createUnderParent'][data-parent-id='#{categories(:food_and_drink).id}']", count: 0
  end

  test "the create form assigns through the transaction category endpoint" do
    get category_dropdown_url(transaction_id: @transaction.id)

    assert_select "form[action='#{transaction_category_path(@transaction.entry)}'][data-category-quick-create-target=assignForm]"
  end
end
