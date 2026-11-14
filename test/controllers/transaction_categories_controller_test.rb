require "test_helper"

class TransactionCategoriesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(rule_prompts_disabled: false, rule_prompt_dismissed_at: nil)
    @entry = create_transaction(account: accounts(:depository), category: categories(:food_and_drink))
  end

  test "clearing a category does not offer a rule" do
    patch transaction_category_url(@entry), params: {
      entry: { entryable_type: "Transaction", entryable_attributes: { id: @entry.entryable_id, category_id: "" } }
    }

    assert_redirected_to transaction_path(@entry)
    assert_nil @entry.reload.transaction.category_id
    assert_nil flash[:cta]
  end

  test "setting a category offers a rule" do
    @entry.transaction.update!(category: nil)

    patch transaction_category_url(@entry), params: {
      entry: { entryable_type: "Transaction", entryable_attributes: { id: @entry.entryable_id, category_id: categories(:food_and_drink).id } }
    }

    assert_equal "category_rule", flash[:cta].with_indifferent_access[:type]
  end
end
