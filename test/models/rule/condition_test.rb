require "test_helper"

class Rule::ConditionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @transaction_rule = rules(:one)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @grocery_category = @family.categories.create!(name: "Grocery")
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")

    # Some sample transactions to work with
    create_transaction(date: Date.current, account: @account, amount: 100, name: "Rule test transaction1", merchant: @whole_foods_merchant)
    create_transaction(date: Date.current, account: @account, amount: -200, name: "Rule test transaction2")
    create_transaction(date: 1.day.ago.to_date, account: @account, amount: 50, name: "Rule test transaction3")
    create_transaction(date: 1.year.ago.to_date, account: @account, amount: 10, name: "Rule test transaction4", merchant: @whole_foods_merchant)
    create_transaction(date: 1.year.ago.to_date, account: @account, amount: 1000, name: "Rule test transaction5")

    @rule_scope = @account.transactions
  end

  test "applies transaction_name condition" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_name",
      operator: "=",
      value: "Rule test transaction1"
    )

    scope = condition.prepare(scope)

    assert_equal 5, scope.count

    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
  end

  test "applies transaction_amount condition using absolute values" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_amount",
      operator: ">",
      value: "50"
    )

    scope = condition.prepare(scope)

    filtered = condition.apply(scope)
    assert_equal 3, filtered.count
  end

  test "applies transaction_amount not equal operator using absolute values" do
    create_transaction(date: Date.current, account: @account, amount: -100, name: "Rule test transaction negative 100")
    scope = @account.transactions

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_amount",
      operator: "!=",
      value: "100"
    )

    scope = condition.prepare(scope)

    filtered = condition.apply(scope)
    # Absolute amounts: 100, -100, 200, 50, 10, 1000 — exclude both ±100
    assert_equal 4, filtered.count
    assert_not filtered.any? { |txn| txn.entry.amount.abs == 100 }
  end

  test "applies transaction_merchant condition" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_merchant",
      operator: "=",
      value: @whole_foods_merchant.id
    )

    scope = condition.prepare(scope)

    filtered = condition.apply(scope)
    assert_equal 2, filtered.count
  end

  test "applies compound and condition" do
    scope = @rule_scope

    parent_condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "compound",
      operator: "and",
      sub_conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @whole_foods_merchant.id
        ),
        Rule::Condition.new(
          condition_type: "transaction_amount",
          operator: "<",
          value: "50"
        )
      ]
    )

    scope = parent_condition.prepare(scope)

    filtered = parent_condition.apply(scope)
    assert_equal 1, filtered.count
  end

  test "applies compound or condition" do
    scope = @rule_scope

    parent_condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "compound",
      operator: "or",
      sub_conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @whole_foods_merchant.id
        ),
        Rule::Condition.new(
          condition_type: "transaction_amount",
          operator: "<",
          value: "50"
        )
      ]
    )

    scope = parent_condition.prepare(scope)

    filtered = parent_condition.apply(scope)
    assert_equal 2, filtered.count
  end

  test "applies transaction_category condition" do
    scope = @rule_scope

    # Set category for one transaction
    @account.transactions.first.update!(category: @grocery_category)

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_category",
      operator: "=",
      value: @grocery_category.id
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal @grocery_category.id, filtered.first.category_id
  end

  test "applies is_null condition for transaction_category" do
    scope = @rule_scope

    # Set category for one transaction
    @account.transactions.first.update!(category: @grocery_category)

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_category",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 4, filtered.count
    assert filtered.all? { |t| t.category_id.nil? }
  end

  test "applies is_null condition for transaction_merchant" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_merchant",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 3, filtered.count
    assert filtered.all? { |t| t.merchant_id.nil? }
  end

  test "applies transaction_details condition with like operator" do
    scope = @rule_scope

    # Create a transaction with extra details (simulating PayPal with underlying merchant)
    paypal_entry = create_transaction(
      date: Date.current,
      account: @account,
      amount: 75,
      name: "PayPal"
    )
    paypal_entry.transaction.update!(
      extra: {
        "plaid" => {
          "payee" => "Amazon via PayPal",
          "description" => "Purchase from Amazon",
          "memo" => "Order #12345"
        }
      }
    )

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "like",
      value: "Amazon"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal paypal_entry.transaction.id, filtered.first.id
  end

  test "applies transaction_details condition with equal operator case-sensitive" do
    scope = @rule_scope

    # Create transaction with specific details
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      amount: 100,
      name: "PayPal"
    )
    transaction_entry.transaction.update!(
      extra: {
        "plaid" => {
          "payee" => "Netflix"
        }
      }
    )

    # Test case-sensitive match (should match)
    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "=",
      value: "Netflix"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)
    assert_equal 1, filtered.count

    # Test case-sensitive match (should NOT match due to case difference)
    condition_lowercase = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "=",
      value: "netflix"
    )

    scope = condition_lowercase.prepare(scope)
    filtered = condition_lowercase.apply(scope)
    assert_equal 0, filtered.count
  end

  test "applies transaction_details condition with is_null operator" do
    scope = @rule_scope

    # Create transaction with extra details
    transaction_with_details = create_transaction(
      date: Date.current,
      account: @account,
      amount: 50,
      name: "Transaction with details"
    )
    transaction_with_details.transaction.update!(
      extra: { "plaid" => { "payee" => "Test Merchant" } }
    )

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    # Should return all original transactions (which have no extra details) but not the new one
    assert_equal 5, filtered.count
    assert_not filtered.map(&:id).include?(transaction_with_details.transaction.id)
  end

  test "applies transaction_notes condition" do
    scope = @rule_scope

    # Add notes to one transaction
    transaction_entry = @account.entries.first
    transaction_entry.update!(notes: "Important: This is a business expense")

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_notes",
      operator: "like",
      value: "business expense"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal transaction_entry.transaction.id, filtered.first.id
  end

  test "applies transaction_notes condition with is_null operator" do
    scope = @rule_scope

    # Add notes to one transaction
    transaction_entry = @account.entries.first
    transaction_entry.update!(notes: "Some notes")

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_notes",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    # Should return all transactions without notes
    assert_equal 4, filtered.count
    assert_not filtered.map(&:id).include?(transaction_entry.transaction.id)
  end

  test "does not contain also matches transactions without the field" do
    with_notes = @account.entries.first
    with_notes.update!(notes: "Business lunch")

    filtered = apply_condition(condition_type: "transaction_notes", operator: "not_like", value: "business")

    # The four transactions with NULL notes match, the one that contains the text does not
    assert_equal 4, filtered.count
    assert_not_includes filtered.map(&:id), with_notes.transaction.id
  end

  test "not equal to on a select field also matches transactions without a value" do
    filtered = apply_condition(condition_type: "transaction_merchant", operator: "!=", value: @whole_foods_merchant.id)

    assert_equal 3, filtered.count
    assert filtered.all? { |t| t.merchant_id.nil? }
  end

  test "not equal to on text compares the normalised name" do
    filtered = apply_condition(condition_type: "transaction_name", operator: "!=", value: "  Rule test   transaction1 ")

    assert_equal 4, filtered.count
  end

  test "is not empty matches transactions that have a value" do
    filtered = apply_condition(condition_type: "transaction_merchant", operator: "is_not_null", value: nil)

    assert_equal 2, filtered.count
  end

  test "valueless operators need no value" do
    %w[is_null is_not_null].each do |operator|
      condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "transaction_notes", operator: operator, value: nil)
      assert condition.valid?, "#{operator}: #{condition.errors.full_messages.to_sentence}"
    end
  end

  test "transaction_tag matches transactions with the tag" do
    work, home = tags_on_transactions

    filtered = apply_condition(condition_type: "transaction_tag", operator: "=", value: work.id)

    assert_equal [ "Rule test transaction1", "Rule test transaction2" ].sort, filtered.map { |t| t.entry.name }.sort
    assert_equal 2, filtered.count, "a transaction with several tags is returned once"
    assert home
  end

  test "transaction_tag not equal to matches transactions without that tag, untagged ones included" do
    work, = tags_on_transactions

    filtered = apply_condition(condition_type: "transaction_tag", operator: "!=", value: work.id)

    assert_equal 3, filtered.count
  end

  test "transaction_tag is empty and is not empty split tagged from untagged" do
    tags_on_transactions

    assert_equal 3, apply_condition(condition_type: "transaction_tag", operator: "is_null", value: nil).count
    assert_equal 2, apply_condition(condition_type: "transaction_tag", operator: "is_not_null", value: nil).count
  end

  test "two ANDed transaction_tag conditions match a transaction with both tags" do
    work, home = tags_on_transactions
    rule = @family.rules.create!(
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_tag", operator: "=", value: work.id),
        Rule::Condition.new(condition_type: "transaction_tag", operator: "=", value: home.id)
      ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    assert_equal [ "Rule test transaction1" ], rule.matching_scope.map { |t| t.entry.name }
  end

  test "transaction_tag offers the family's tags" do
    @family.tags.create!(name: "Zeta")
    @family.tags.create!(name: "Alpha")
    rule = @family.rules.build(resource_type: "transaction")

    # "Test" is the empty family's fixture tag; another family's tags are not offered
    assert_equal [ "Alpha", "Test", "Zeta" ], rule.registry.get_filter!("transaction_tag").options.map(&:first)
  end

  test "operator labels come from the locale" do
    labels = @transaction_rule.registry.get_filter!("transaction_name").operators.to_h(&:reverse)

    assert_equal "Starts with", labels["starts_with"]
    assert_equal "Is not empty", labels["is_not_null"]
    assert_equal "Matches regex", labels["matches_regex"]
  end

  test "operator_display shows the operator label" do
    condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "transaction_name", operator: "not_like", value: "x")

    assert_equal "Does not contain", condition.operator_display
  end

  test "rejects an unknown condition type" do
    condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "bogus", operator: "=", value: "x")

    assert_not condition.valid?
    assert condition.errors.of_kind?(:condition_type, :inclusion)
  end

  test "rejects an operator the filter does not offer" do
    condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "transaction_type", operator: "like", value: "income")

    assert_not condition.valid?
    assert condition.errors.of_kind?(:operator, :inclusion)

    compound = Rule::Condition.new(rule: @transaction_rule, condition_type: "compound", operator: "xor")
    assert_not compound.valid?
    assert compound.errors.of_kind?(:operator, :inclusion)
  end

  test "maps the legacy name condition type on save" do
    condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "name", operator: "like", value: "coffee")

    assert condition.valid?
    assert_equal "transaction_name", condition.condition_type
  end

  test "a stored unknown condition type renders as unsupported and matches nothing" do
    condition = @transaction_rule.conditions.create!(condition_type: "transaction_name", operator: "like", value: "Rule test")
    condition.update_columns(condition_type: "removed_filter")
    condition.reload

    assert_instance_of Rule::ConditionFilter::Unsupported, condition.filter
    assert_equal "Unsupported (removed_filter)", condition.filter.label
    assert_equal 0, condition.apply(@rule_scope).count
  end

  test "rejects null bytes and malformed UTF-8 as invalid text" do
    [ "bad\u0000value", "bad\xFFvalue".dup.force_encoding(Encoding::UTF_8) ].each do |value|
      condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "transaction_name", operator: "like", value: value)

      assert_not condition.valid?
      assert_equal [ { error: :invalid } ], condition.errors.details[:value]
    end

    condition = Rule::Condition.new(rule: @transaction_rule, condition_type: "transaction_\u0000name", operator: "like", value: "x")
    assert_not condition.valid?
    assert condition.errors.of_kind?(:condition_type, :invalid)
  end

  private
    def apply_condition(condition_type:, operator:, value:)
      condition = Rule::Condition.new(rule: @transaction_rule, condition_type: condition_type, operator: operator, value: value)
      condition.apply(condition.prepare(@rule_scope))
    end

    # transaction1 has both tags, transaction2 only "Work", the other three none
    def tags_on_transactions
      work = @family.tags.create!(name: "Work")
      home = @family.tags.create!(name: "Home")
      entries = @account.entries.index_by(&:name)

      entries["Rule test transaction1"].transaction.update!(tags: [ work, home ])
      entries["Rule test transaction2"].transaction.update!(tags: [ work ])

      [ work, home ]
    end
end
