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

  # w2-transfers transfer-form-fixes
  test "a confirmed transfer's inflow leg does not take a category" do
    outflow, inflow = contribution_legs

    patch transaction_category_url(inflow.entry), params: {
      entry: { entryable_type: "Transaction", entryable_attributes: { id: inflow.id, category_id: categories(:food_and_drink).id } }
    }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_nil inflow.reload.category_id
    assert_not_equal categories(:food_and_drink), outflow.reload.category
  end

  test "a confirmed investment contribution's outflow leg takes a category" do
    outflow, _inflow = contribution_legs

    patch transaction_category_url(outflow.entry), params: {
      entry: { entryable_type: "Transaction", entryable_attributes: { id: outflow.id, category_id: categories(:food_and_drink).id } }
    }, as: :turbo_stream

    assert_response :success
    assert_equal categories(:food_and_drink), outflow.reload.category
  end

  private
    def contribution_legs
      outflow = Transaction.new
      accounts(:depository).entries.create!(name: "Contribution", amount: 500, currency: "USD", date: Date.current, entryable: outflow)
      inflow = Transaction.new
      accounts(:investment).entries.create!(name: "Contribution", amount: -500, currency: "USD", date: Date.current, entryable: inflow)
      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
      [ outflow, inflow ]
    end
end
