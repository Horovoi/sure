require "test_helper"

class Family::AutoCategorizeTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    # The empty family: fixture families carry categorized transactions that would
    # change the Bayes training set
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Auto categorize", balance: 100, currency: "UAH", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Кава")
    @groceries = @family.categories.create!(name: "Продукти")
    @llm_provider = mock
  end

  test "Bayes covers everything: the LLM is never asked" do
    train_two_categories
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
    @llm_provider.expects(:auto_categorize).never
    txn = create_transaction(account: @account, name: "Aroma Kava кава").transaction

    assert_difference "DataEnrichment.count", 1 do
      assert_equal 1, @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal @coffee, txn.reload.category
    assert_equal "bayes", txn.data_enrichments.find_by(attribute_name: "category_id").source
  end

  test "Bayes runs before the LLM, which gets only the rest" do
    train_two_categories
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
    bayes_txn = create_transaction(account: @account, name: "Aroma Kava кава").transaction
    llm_txn = create_transaction(account: @account, name: "Нова крамниця").transaction
    other = @family.categories.create!(name: "Інше")

    @llm_provider.expects(:auto_categorize).with do |*args, **kwargs|
      transactions = (kwargs.presence || args.last)[:transactions]
      # Bayes already categorized its transaction before the LLM call
      assert_equal @coffee, bayes_txn.reload.category
      assert_equal [ llm_txn.id ], transactions.map { |t| t[:id] }
      true
    end.returns(provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: llm_txn.id, category_name: other.name)
    ])).once

    assert_equal 2, @family.auto_categorize_transactions([ bayes_txn.id, llm_txn.id ])
    assert_equal other, llm_txn.reload.category
    assert_equal "ai", llm_txn.lock_source(:category_id)
  end

  test "without an LLM provider the rest is left as it is" do
    train_two_categories
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)
    bayes_txn = create_transaction(account: @account, name: "Aroma Kava кава").transaction
    unknown = create_transaction(account: @account, name: "Нова крамниця").transaction

    assert_equal 1, @family.auto_categorize_transactions([ bayes_txn.id, unknown.id ])
    assert_equal @coffee, bayes_txn.reload.category
    assert_nil unknown.reload.category
  end

  test "with nothing categorized and no LLM provider it still reports the missing provider" do
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)
    txn = create_transaction(account: @account, name: "Щось нове").transaction

    error = assert_raises(Family::AutoCategorizer::Error) { @family.auto_categorize_transactions([ txn.id ]) }
    assert_equal "No LLM provider for auto-categorization", error.message
  end

  private
    def train_two_categories
      10.times { create_transaction(account: @account, name: "Aroma Kava кава", category: @coffee) }
      10.times { create_transaction(account: @account, name: "Сільпо продукти", category: @groceries) }
    end
end
