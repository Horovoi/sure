require "test_helper"

class RuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "basic rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  test "compound rule" do
    transaction_entry1 = create_transaction(date: Date.current, amount: 50, account: @account, merchant: @whole_foods_merchant)
    transaction_entry2 = create_transaction(date: Date.current, amount: 100, account: @account, merchant: @whole_foods_merchant)

    # Assign "Groceries" to transactions with a merchant of "Whole Foods" and an amount greater than $60
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id),
          Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60)
        ])
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry1.reload
    transaction_entry2.reload

    assert_nil transaction_entry1.transaction.category
    assert_equal @groceries_category, transaction_entry2.transaction.category
  end

  test "exclude transaction rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    assert_not transaction_entry.excluded, "Transaction should not be excluded initially"

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert transaction_entry.excluded, "Transaction should be excluded after rule applies"
  end

  test "exclude transaction rule respects attribute locks" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)
    transaction_entry.lock_attr!(:excluded)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert_not transaction_entry.excluded, "Transaction should not be excluded when attribute is locked"
  end

  test "transaction name rules normalize whitespace in comparisons" do
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Company  -   Mobile",
      amount: 80
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Company - Mobile") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    assert_equal 1, rule.affected_resource_count

    rule.apply
    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  # Artificial limitation put in place to prevent users from creating overly complex rules
  # Rules should be shallow and wide
  test "no nested compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
            Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Starbucks")
          ])
        ])
      ]
    )

    assert_not rule.valid?
    assert_equal [ "Compound conditions cannot be nested" ], rule.errors.full_messages
  end

  test "rule matching on transaction details" do
    # Create PayPal transaction with underlying merchant in details
    paypal_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 50
    )
    paypal_entry.transaction.update!(
      extra: {
        "plaid" => {
          "payee" => "Whole Foods via PayPal",
          "description" => "Grocery shopping"
        }
      }
    )

    # Create another PayPal transaction with different underlying merchant
    paypal_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 100
    )
    paypal_entry2.transaction.update!(
      extra: {
        "plaid" => {
          "payee" => "Amazon via PayPal"
        }
      }
    )

    # Rule to categorize PayPal transactions containing "Whole Foods" in details
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_details", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    paypal_entry.reload
    paypal_entry2.reload

    assert_equal @groceries_category, paypal_entry.transaction.category, "PayPal transaction with 'Whole Foods' in details should be categorized"
    assert_nil paypal_entry2.transaction.category, "PayPal transaction without 'Whole Foods' in details should not be categorized"
  end

  test "rule matching on transaction notes" do
    # Create transaction with notes
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 50
    )
    transaction_entry.update!(notes: "Business lunch with client")

    # Create another transaction without relevant notes
    transaction_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 100
    )
    transaction_entry2.update!(notes: "Personal expense")

    # Rule to categorize transactions with "business" in notes
    business_category = @family.categories.create!(name: "Business")
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_notes", operator: "like", value: "business") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: business_category.id) ]
    )

    rule.apply

    transaction_entry.reload
    transaction_entry2.reload

    assert_equal business_category, transaction_entry.transaction.category, "Transaction with 'business' in notes should be categorized"
    assert_nil transaction_entry2.transaction.category, "Transaction without 'business' in notes should not be categorized"
  end

  test "total_affected_resource_count deduplicates overlapping rules" do
    # Create transactions
    transaction_entry1 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 50)
    transaction_entry2 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 100)
    transaction_entry3 = create_transaction(date: Date.current, account: @account, name: "Target", amount: 75)

    # Rule 1: Match transactions with name "Whole Foods" (matches txn 1 and 2)
    rule1 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 2: Match transactions with amount > 60 (matches txn 2 and 3)
    rule2 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 1 affects 2 transactions, Rule 2 affects 2 transactions
    # But transaction_entry2 is matched by both, so total unique should be 3
    assert_equal 2, rule1.affected_resource_count
    assert_equal 2, rule2.affected_resource_count
    assert_equal 3, Rule.total_affected_resource_count([ rule1, rule2 ])
  end

  test "total_affected_resource_count returns zero for empty rules" do
    assert_equal 0, Rule.total_affected_resource_count([])
  end

  test "rule matching on transaction account" do
    # Create a second account
    other_account = @family.accounts.create!(
      name: "Other account",
      balance: 500,
      currency: "USD",
      accountable: Depository.new
    )

    # Transaction on the target account
    transaction_entry1 = create_transaction(
      date: Date.current,
      account: @account,
      amount: 50
    )

    # Transaction on another account
    transaction_entry2 = create_transaction(
      date: Date.current,
      account: other_account,
      amount: 75
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_account",
          operator: "=",
          value: @account.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    rule.apply

    transaction_entry1.reload
    transaction_entry2.reload

    assert_equal @groceries_category, transaction_entry1.transaction.category,
      "Transaction on selected account should be categorized"

    assert_nil transaction_entry2.transaction.category,
      "Transaction on other account should not be categorized"
  end

  test "displayed_condition skips an empty compound condition" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "starbucks")
      ]
    )

    displayed = rule.displayed_condition

    assert_equal "transaction_name", displayed.condition_type
    assert_equal "starbucks", displayed.value
    assert_equal 0, rule.additional_displayable_conditions_count
    assert_equal "If transaction name like starbucks", rule.primary_condition_title
  end

  test "a rule with only an empty compound condition has no condition title" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [ Rule::Condition.new(condition_type: "compound", operator: "and") ]
    )

    assert_nil rule.displayed_condition
    assert_equal I18n.t("rules.no_condition"), rule.primary_condition_title
  end

  test "additional_displayable_conditions_count ignores empty compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "first"),
        Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 100)
      ]
    )

    assert_equal 1, rule.additional_displayable_conditions_count
  end

  test "matches_transaction? follows the rule's conditions" do
    matching = create_transaction(date: Date.current, account: @account, name: "Coffee shop")
    other = create_transaction(date: Date.current, account: @account, name: "Hardware store")

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "coffee") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    assert rule.matches_transaction?(matching.transaction)
    assert_not rule.matches_transaction?(other.transaction)
  end

  test "a new rule is numbered after the family's last rule" do
    first = create_simple_rule
    second = create_simple_rule

    assert_equal first.position + 1, second.position
    assert_equal [ first, second ], @family.rules.ordered.to_a
  end

  test "a rule created with a position keeps it" do
    rule = @family.rules.create!(resource_type: "transaction", position: 7, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    assert_equal 7, rule.position
  end

  test "update_positions! sets the run order" do
    a = create_simple_rule
    b = create_simple_rule
    c = create_simple_rule

    Rule.update_positions!(@family, [ c.id, a.id, b.id ])

    assert_equal [ c, a, b ], @family.rules.ordered.to_a
    assert_equal [ 1, 2, 3 ], @family.rules.ordered.pluck(:position)
  end

  test "update_positions! refuses a list that leaves out or repeats a rule" do
    a = create_simple_rule
    b = create_simple_rule

    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ a.id ]) }
    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ a.id, a.id ]) }
    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ a.id, b.id, SecureRandom.uuid ]) }
  end

  test "active_rules_above lists only the active rules higher in the list" do
    active_above = create_simple_rule(active: true)
    create_simple_rule(active: false)
    rule = create_simple_rule
    create_simple_rule(active: true)

    assert_equal [ active_above ], rule.active_rules_above.to_a
  end

  test "excluding_transaction_ids drops the given transactions" do
    kept = create_transaction(date: Date.current, account: @account, name: "Kept")
    dropped = create_transaction(date: Date.current, account: @account, name: "Dropped")
    scope = @family.transactions.where(id: [ kept.entryable_id, dropped.entryable_id ])

    assert_equal [ kept.entryable_id ], Rule.excluding_transaction_ids(scope, [ dropped.entryable_id ]).pluck(:id)
    assert_equal 2, Rule.excluding_transaction_ids(scope, []).count
  end

  test "apply skips transactions a rule above claimed for the same attribute" do
    claimed = create_transaction(date: Date.current, account: @account, name: "Coffee one")
    free = create_transaction(date: Date.current, account: @account, name: "Coffee two")
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "coffee") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply(claimed_ids: { category_id: Set[claimed.entryable_id] })

    assert_nil claimed.transaction.reload.category
    assert_equal @groceries_category, free.transaction.reload.category
  end

  test "an AI action stays readable after the provider goes away" do
    Provider::Registry.stubs(:get_provider).with(:openai).returns(stub("llm"))
    rule = @family.rules.create!(resource_type: "transaction", actions: [ Rule::Action.new(action_type: "auto_categorize") ])
    Provider::Registry.unstub(:get_provider)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)

    rule = Rule.find(rule.id)

    assert_equal "auto_categorize", rule.actions.first.executor.key
    assert_not_includes Rule.new(family: @family, resource_type: "transaction").action_executors.map(&:key), "auto_categorize"
  end

  private
    def create_simple_rule(active: false)
      @family.rules.create!(resource_type: "transaction", active: active, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
end
