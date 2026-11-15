require "test_helper"

class Rule::ActionExecutor::BayesCategorizeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Bayes rule", balance: 1000, currency: "UAH", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Продукти")
    @transport = @family.categories.create!(name: "Транспорт")
    10.times { create_transaction(account: @account, name: "Сільпо продукти", category: @groceries) }
    10.times { create_transaction(account: @account, name: "Uklon поїздка", category: @transport) }
    @txn = create_transaction(account: @account, name: "Сільпо").transaction
    # No AI provider: the classifier needs none
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)
  end

  test "is offered without an AI provider and claims the category without reserving it" do
    rule = Rule.new(family: @family, resource_type: "transaction")
    executor = rule.registry.get_executor!("bayes_categorize")

    assert_includes rule.action_executors.map(&:key), "bayes_categorize"
    assert_not_includes rule.action_executors.map(&:key), "auto_categorize"
    assert_equal [ :category_id ], executor.claimed_attributes
    assert_not executor.reserves_claimed_attributes?
    assert_equal "function", executor.type
  end

  test "categorizes the uncategorized matches synchronously" do
    rule = bayes_rule

    assert_equal 1, rule.apply

    assert_equal @groceries, @txn.reload.category
    assert_equal "bayes", @txn.lock_source(:category_id)
  end

  test "a category rule above wins over the classifier" do
    category_rule("Above", @transport)
    bayes_rule

    run_rules

    assert_equal @transport, @txn.reload.category
    assert_not @txn.locked?(:category_id)
  end

  test "a category rule below may still replace the classifier's guess" do
    bayes_rule
    category_rule("Below", @transport)

    runs = run_rules

    assert_equal %w[success success], runs.map(&:status)
    assert_equal @transport, @txn.reload.category
  end

  private
    def bayes_rule
      @family.rules.create!(
        name: "Classifier",
        resource_type: "transaction",
        active: true,
        actions: [ Rule::Action.new(action_type: "bayes_categorize") ]
      )
    end

    def category_rule(name, category)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Сільпо") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end

    def run_rules
      Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "scheduled").run
    end
end
