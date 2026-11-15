require "test_helper"

# A matches_regex rule resolves its matches under a statement timeout. A pattern
# that times out fails its own run and nothing else.
class Rule::RegexExecutionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Regex test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")

    @amazon = create_transaction(account: @account, name: "AMZN Mktp US*2K4").transaction
    @other = create_transaction(account: @account, name: "Hardware store").transaction
  end

  test "a regex rule applies its actions to the transactions it matches" do
    rule = create_regex_rule("^amzn\\s+mktp", category: @groceries)

    assert_equal 1, rule.affected_resource_count
    assert rule.matches_transaction?(@amazon)
    assert_not rule.matches_transaction?(@other)

    run_active_rules

    assert_equal @groceries, @amazon.reload.category
    assert_nil @other.reload.category
  end

  test "a regex inside a compound condition goes through the timeout too" do
    rule = @family.rules.build(resource_type: "transaction", active: true, actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id) ])
    compound = rule.conditions.build(condition_type: "compound", operator: "or")
    compound.sub_conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: "^hardware")
    compound.sub_conditions.build(condition_type: "transaction_name", operator: "like", value: "nothing matches this")
    rule.save!

    Rule::SafeRegex.expects(:with_timeout).once.yields.returns([ @other.id ])

    assert_equal [ @other.id ], rule.matching_scope.pluck(:id)
  end

  test "a rule without a regex does not use the timeout" do
    rule = @family.rules.create!(
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "starts_with", value: "AMZN") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id) ]
    )
    Rule::SafeRegex.expects(:with_timeout).never

    assert_equal [ @amazon.id ], rule.matching_scope.pluck(:id)
  end

  test "a timed-out pattern fails its own run and the rules below still run" do
    create_regex_rule("^amzn", category: @groceries)
    @family.rules.create!(
      name: "Below",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "AMZN") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @dining.id) ]
    )
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError, "regular expression exceeded 5000 ms")

    runs = nil
    assert_nothing_raised { runs = run_active_rules }

    assert_equal %w[failed success], runs.map { |run| run.reload.status }
    assert_match "regular expression exceeded", runs.first.error_message
    # The failed rule matched nothing, so it claimed nothing
    assert_equal @dining, @amazon.reload.category
  end

  test "a timed-out pattern reads as no match outside a run" do
    rule = create_regex_rule("^amzn", category: @groceries)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_equal 0, rule.affected_resource_count
    assert_not rule.matches_transaction?(@amazon)
    assert_equal 0, Rule.total_affected_resource_count([ rule ])
  end

  test "the one-transaction check runs the pattern on that transaction only" do
    rule = create_regex_rule("^amzn", category: @groceries)

    assert_equal [ @amazon.id ], rule.matching_scope(only_id: @amazon.id).pluck(:id)
    assert_empty rule.matching_scope(only_id: @other.id).pluck(:id)
  end

  private
    def run_active_rules
      Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "scheduled").run
    end

    def create_regex_rule(pattern, category:)
      @family.rules.create!(
        name: "Regex",
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: pattern) ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
