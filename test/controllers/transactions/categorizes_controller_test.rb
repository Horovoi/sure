require "test_helper"

class Transactions::CategorizesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    # Only the transactions each test creates are uncategorized
    Transaction.where(id: @family.entries.where(entryable_type: "Transaction").select(:entryable_id), category_id: nil)
               .update_all(category_id: @category.id)
  end

  # --- show ---

  test "show redirects with a notice when nothing is left to categorize" do
    get transactions_categorize_url

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.categorizes.show.all_done"), flash[:notice]
  end

  test "show lists the largest group first and position skips groups" do
    2.times { create_transaction(name: "Netflix") }
    3.times { create_transaction(name: "Corner shop") }

    get transactions_categorize_url

    assert_response :success
    assert_select "#categorize_group_title h2", text: "Corner shop"
    assert_select "input[name='categorize[entry_ids][]']", count: 3

    get transactions_categorize_url(position: 1)

    assert_response :success
    assert_select "#categorize_group_title h2", text: "Netflix"
  end

  test "show groups by merchant before name and splits income from expense" do
    create_transaction(name: "STARBUCKS 123", merchant: merchants(:starbucks))
    create_transaction(name: "Starbucks card", merchant: merchants(:starbucks))
    create_transaction(name: "Refund", merchant: merchants(:starbucks), amount: -5)

    get transactions_categorize_url

    assert_response :success
    assert_select "#categorize_group_title h2", text: "Starbucks Coffee"
    assert_select "input[name='categorize[entry_ids][]']", count: 2
    assert_select "input[name='categorize[merchant_id]'][value=?]", merchants(:starbucks).id
    assert_select "#categorize_group_title", text: /#{I18n.t("transactions.categorizes.show.type_expense")}/

    get transactions_categorize_url(position: 1)

    assert_select "#categorize_group_title", text: /#{I18n.t("transactions.categorizes.show.type_income")}/
    assert_select "input[name='categorize[entry_ids][]']", count: 1
  end

  test "show leaves out transfers, excluded and categorized transactions" do
    create_transaction(name: "Shop")
    create_transaction(name: "Shop", kind: "funds_movement")
    create_transaction(name: "Shop", excluded: true)
    create_transaction(name: "Shop", category: @category)

    get transactions_categorize_url

    assert_response :success
    assert_select "input[name='categorize[entry_ids][]']", count: 1
  end

  test "show never lists another family's transactions" do
    other_entry = other_family_transaction(name: "Shop")
    create_transaction(name: "Shop")

    get transactions_categorize_url

    assert_response :success
    assert_select "input[name='categorize[entry_ids][]']", count: 1
    assert_select "input[value=?]", other_entry.id, count: 0
  end

  test "show renders full dates, with the year" do
    create_transaction(name: "Shop", date: Date.new(2024, 7, 8))

    get transactions_categorize_url

    assert_response :success
    assert_match Date.new(2024, 7, 8).strftime(@family.date_format), response.body
  end

  test "show offers only categories of the group's classification" do
    income_category = @family.categories.create!(name: "Salary", classification: "income", color: "#22c55e")
    create_transaction(name: "Payroll", amount: -500)

    get transactions_categorize_url

    assert_response :success
    assert_select "select[data-entry-id] option[value=?]", income_category.id
    assert_select "select[data-entry-id] option[value=?]", @category.id, count: 0
  end

  test "show redirects with the remaining count when the user skipped past the last group" do
    create_transaction(name: "Shop")

    get transactions_categorize_url(position: 5)

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.categorizes.show.skipped_rest", count: 1), flash[:notice]
  end

  # --- create ---

  test "create sets the category as a user edit and leaves unchecked rows alone" do
    picked = 2.times.map { create_transaction(name: "Shop") }
    left_out = create_transaction(name: "Shop")

    post transactions_categorize_url, params: {
      categorize: {
        category_id: @category.id, position: 0, transaction_type: "expense", grouping_key: "Shop",
        entry_ids: picked.map(&:id), all_entry_ids: (picked + [ left_out ]).map(&:id)
      }
    }, as: :turbo_stream

    assert_response :success
    picked.each do |entry|
      entry.reload
      assert_equal @category, entry.transaction.category
      assert entry.transaction.user_locked?(:category_id), "the category is locked against rules"
      assert entry.user_modified?
      assert_match "turbo-stream action=\"remove\" target=\"categorize_entry_#{entry.id}\"", response.body
    end
    assert_nil left_out.reload.transaction.category
    assert_match "categorize_group_summary", response.body
  end

  test "create redirects to the next group when none of the group is left" do
    entry = create_transaction(name: "Shop")

    post transactions_categorize_url, params: {
      categorize: { category_id: @category.id, position: 0, entry_ids: [ entry.id ], all_entry_ids: [ entry.id ] }
    }, as: :turbo_stream

    assert_response :success
    assert_match "turbo-stream action=\"redirect\" target=\"#{transactions_categorize_path(position: 0)}\"", response.body
    assert_equal I18n.t("transactions.categorizes.create.categorized", count: 1, category: @category.name), flash[:notice]
  end

  test "create with create_rule saves a name rule prefilled from the group" do
    entry = create_transaction(name: "Corner shop")

    assert_difference -> { @family.rules.count }, 1 do
      post transactions_categorize_url, params: {
        categorize: {
          category_id: @category.id, position: 0, transaction_type: "expense", grouping_key: "Corner   shop ",
          create_rule: "1", entry_ids: [ entry.id ], all_entry_ids: [ entry.id ]
        }
      }
    end

    rule = @family.rules.order(:created_at).last
    assert_equal "Corner shop", rule.name
    assert rule.active?
    name_condition = rule.conditions.find_by!(condition_type: "transaction_name")
    assert_equal [ "like", "Corner shop" ], [ name_condition.operator, name_condition.value ]
    type_condition = rule.conditions.find_by!(condition_type: "transaction_type")
    assert_equal [ "=", "expense" ], [ type_condition.operator, type_condition.value ]
    action = rule.actions.sole
    assert_equal [ "set_transaction_category", @category.id ], [ action.action_type, action.value ]
  end

  test "create with create_rule for a merchant group matches the merchant" do
    entry = create_transaction(name: "STARBUCKS 123", merchant: merchants(:starbucks))

    post transactions_categorize_url, params: {
      categorize: {
        category_id: @category.id, position: 0, transaction_type: "expense", grouping_key: "Starbucks Coffee",
        merchant_id: merchants(:starbucks).id, create_rule: "1", entry_ids: [ entry.id ], all_entry_ids: [ entry.id ]
      }
    }

    rule = @family.rules.order(:created_at).last
    assert_equal "Starbucks Coffee", rule.name
    merchant_condition = rule.conditions.find_by!(condition_type: "transaction_merchant")
    assert_equal merchants(:starbucks).id, merchant_condition.value
    assert_not rule.conditions.exists?(condition_type: "transaction_name")
  end

  test "create without create_rule saves no rule" do
    entry = create_transaction(name: "Shop")

    assert_no_difference -> { Rule.count } do
      post transactions_categorize_url, params: {
        categorize: { category_id: @category.id, position: 0, grouping_key: "Shop", create_rule: "0",
                      entry_ids: [ entry.id ], all_entry_ids: [ entry.id ] }
      }
    end
  end

  test "create ignores another family's transactions" do
    other_entry = other_family_transaction(name: "Shop")
    entry = create_transaction(name: "Shop")

    post transactions_categorize_url, params: {
      categorize: { category_id: @category.id, position: 0, entry_ids: [ entry.id, other_entry.id ], all_entry_ids: [ entry.id, other_entry.id ] }
    }

    assert_equal @category, entry.reload.transaction.category
    assert_nil other_entry.reload.transaction.category
  end

  test "create refuses another family's category" do
    entry = create_transaction(name: "Shop")

    post transactions_categorize_url, params: {
      categorize: { category_id: categories(:one).id, position: 0, entry_ids: [ entry.id ], all_entry_ids: [ entry.id ] }
    }

    assert_response :not_found
    assert_nil entry.reload.transaction.category
  end

  # --- assign_entry ---

  test "assign_entry categorizes one row as a user edit" do
    entry = create_transaction(name: "Shop")
    other = create_transaction(name: "Shop")

    patch assign_entry_transactions_categorize_url, params: {
      categorize: { entry_id: entry.id, category_id: @category.id, position: 0, all_entry_ids: [ entry.id, other.id ] }
    }, as: :turbo_stream

    assert_response :success
    assert_equal @category, entry.reload.transaction.category
    assert entry.transaction.user_locked?(:category_id)
    assert_nil other.reload.transaction.category
    assert_match "target=\"categorize_entry_#{entry.id}\"", response.body
  end

  test "assign_entry refuses another family's transaction" do
    other_entry = other_family_transaction(name: "Shop")

    patch assign_entry_transactions_categorize_url, params: {
      categorize: { entry_id: other_entry.id, category_id: @category.id, position: 0, all_entry_ids: [ other_entry.id ] }
    }, as: :turbo_stream

    assert_response :not_found
    assert_nil other_entry.reload.transaction.category
  end

  # --- preview_rule ---

  test "preview_rule lists the family's uncategorized transactions that contain the text" do
    match = create_transaction(name: "Corner  Shop 42")
    create_transaction(name: "Bakery")
    other_entry = other_family_transaction(name: "Corner shop")

    get preview_rule_transactions_categorize_url(filter: "corner shop", transaction_type: "expense"), as: :turbo_stream

    assert_response :success
    assert_match "categorize_entry_#{match.id}", response.body
    assert_no_match "Bakery", response.body
    assert_no_match other_entry.id, response.body
  end

  # --- transactions page link ---

  test "the transactions page links to the wizard with the uncategorized count" do
    2.times { create_transaction(name: "Shop") }

    get transactions_url

    assert_response :success
    assert_select "a[href=?]", transactions_categorize_path, text: /#{I18n.t("transactions.index.categorize", count: 2)}/
  end

  test "the transactions page has no wizard link when everything is categorized" do
    get transactions_url

    assert_response :success
    assert_select "a[href=?]", transactions_categorize_path, count: 0
  end

  private
    def other_family_transaction(**attributes)
      account = families(:empty).accounts.create!(
        name: "Other family cash", balance: 0, currency: "USD", accountable: Depository.new
      )
      create_transaction(account: account, **attributes)
    end
end
