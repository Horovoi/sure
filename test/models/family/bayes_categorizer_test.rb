require "test_helper"

class Family::BayesCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Bayes", balance: 1000, currency: "UAH", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Продукти")
    @transport = @family.categories.create!(name: "Транспорт")
  end

  test "tokenizes Cyrillic, apostrophes and mixed scripts" do
    assert_equal %w[сільпо м'ясо київ 123], Family::BayesCategorizer.tokenize("СІЛЬПО м’ясо, Київ #123 і")
    assert_equal %w[uber trip], Family::BayesCategorizer.tokenize("UBER   *trip")
    assert_equal [], Family::BayesCategorizer.tokenize(nil)
  end

  test "categorizes a Cyrillic description it has seen, with a soft bayes lock" do
    train
    txn = create_transaction(account: @account, name: "Сільпо Київ").transaction

    result = categorizer.classify_and_apply([ txn.id ])

    assert_equal [ txn.id ], result.categorized_ids
    assert_equal 1, result.modified_count
    txn.reload
    assert_equal @groceries, txn.category
    assert_equal "bayes", txn.lock_source(:category_id)
    assert txn.soft_locked?(:category_id)
    enrichment = DataEnrichment.find_by!(enrichable: txn, attribute_name: "category_id")
    assert_equal "bayes", enrichment.source
    assert_operator enrichment.metadata["confidence"], :>=, Family::BayesCategorizer::CONFIDENCE_THRESHOLD
  end

  test "leaves a transaction alone when the confidence is below the threshold" do
    train
    # One token from each category: an even split, far below 0.7
    txn = create_transaction(account: @account, name: "Сільпо Uklon").transaction

    assert_nil categorizer.classify(txn)
    result = categorizer.classify_and_apply([ txn.id ])

    assert_empty result.categorized_ids
    assert_nil txn.reload.category
  end

  test "a description made only of unseen words is not classified" do
    train(groceries: 15, transport: 5)
    txn = create_transaction(account: @account, name: "Зовсім новий магазин").transaction

    assert_nil categorizer.classify(txn)
  end

  test "does nothing until there are enough categorized transactions in two categories" do
    train(groceries: 19, transport: 0)
    txn = create_transaction(account: @account, name: "Сільпо").transaction

    assert_not categorizer.enough_training_data?
    assert_empty categorizer.classify_and_apply([ txn.id ]).categorized_ids
    assert_nil txn.reload.category
  end

  test "a training set with no usable tokens classifies nothing and does not raise" do
    20.times { |i| create_transaction(account: @account, name: "-", category: i.even? ? @groceries : @transport) }
    txn = create_transaction(account: @account, name: "Сільпо").transaction

    assert_nil categorizer.classify(txn)
  end

  test "trains only on categories a person chose, not on AI or Bayes guesses" do
    train(groceries: 10, transport: 10)
    # Twenty guesses that would teach "Сільпо" as transport if they counted
    20.times do |i|
      guessed = create_transaction(account: @account, name: "Сільпо", category: @transport).transaction
      guessed.lock_attr!(:category_id, source: i.even? ? "ai" : "bayes")
    end
    txn = create_transaction(account: @account, name: "Сільпо").transaction

    category_id, _confidence = categorizer.classify(txn)

    assert_equal @groceries.id, category_id
  end

  test "rule-set and user-locked categories count as training data" do
    10.times do
      user_set = create_transaction(account: @account, name: "Сільпо", category: @groceries).transaction
      user_set.lock_attr!(:category_id)
    end
    rule = @family.rules.create!(
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Uklon") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @transport.id) ]
    )
    10.times { create_transaction(account: @account, name: "Uklon поїздка") }
    rule.apply

    assert categorizer.enough_training_data?
  end

  test "transfers neither train nor get classified" do
    train
    transfer = create_transaction(account: @account, name: "Сільпо", kind: "funds_movement").transaction

    assert_empty categorizer.classify_and_apply([ transfer.id ]).categorized_ids
    assert_nil transfer.reload.category
  end

  test "one-time transactions are classified" do
    train
    txn = create_transaction(account: @account, name: "Сільпо", kind: "one_time").transaction

    assert_equal [ txn.id ], categorizer.classify_and_apply([ txn.id ]).categorized_ids
  end

  test "keeps only the most recent transactions for training" do
    train
    assert Family::BayesCategorizer.new(@family).enough_training_data?
    assert_not Family::BayesCategorizer.new(@family, training_limit: 5).enough_training_data?
    assert_equal 5_000, Family::BayesCategorizer::MAX_TRAINING_TRANSACTIONS
  end

  test "never touches a transaction that already has a category or a user lock" do
    train
    categorized = create_transaction(account: @account, name: "Сільпо", category: @transport).transaction
    locked = create_transaction(account: @account, name: "Сільпо").transaction
    locked.lock_attr!(:category_id)

    result = categorizer.classify_and_apply([ categorized.id, locked.id ])

    assert_empty result.categorized_ids
    assert_equal @transport, categorized.reload.category
    assert_nil locked.reload.category
  end

  test "a later scheduled rule replaces the bayes category, and the lock goes with it" do
    txn = bayes_categorized_transaction
    rule = category_rule(@transport)

    rule.apply(ignore_attribute_locks: false)

    txn.reload
    assert_equal @transport, txn.category
    assert_not txn.locked?(:category_id)
  end

  test "a forced run replaces the bayes category" do
    txn = bayes_categorized_transaction

    category_rule(@transport).apply(ignore_attribute_locks: true)

    assert_equal @transport, txn.reload.category
    assert_not txn.locked?(:category_id)
  end

  test "a user edit replaces the bayes lock with a user lock" do
    txn = bayes_categorized_transaction

    txn.update!(category: @transport)
    txn.lock_saved_attributes!

    txn.reload
    assert_equal "user", txn.lock_source(:category_id)
    # From now on even a forced rule leaves it alone
    category_rule(@groceries).apply(ignore_attribute_locks: true)
    assert_equal @transport, txn.reload.category
  end

  private
    def categorizer
      Family::BayesCategorizer.new(@family)
    end

    def train(groceries: 10, transport: 10)
      groceries.times { create_transaction(account: @account, name: "Сільпо продукти", category: @groceries) }
      transport.times { create_transaction(account: @account, name: "Uklon поїздка", category: @transport) }
    end

    def bayes_categorized_transaction
      train
      txn = create_transaction(account: @account, name: "Сільпо").transaction
      categorizer.classify_and_apply([ txn.id ])
      txn.reload
      assert_equal "bayes", txn.lock_source(:category_id)
      txn
    end

    def category_rule(category)
      @family.rules.create!(
        resource_type: "transaction",
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Сільпо") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
