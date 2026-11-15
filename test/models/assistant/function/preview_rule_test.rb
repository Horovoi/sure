require "test_helper"

class Assistant::Function::PreviewRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::PreviewRule.new(@user)
    @category = categories(:food_and_drink)
  end

  test "is a read tool" do
    assert_equal :read, @fn.scope_tag
  end

  test "previews an unsaved definition without saving or changing anything" do
    entry = create_transaction(name: "ZXQ Coffee Shop", amount: 4.5)
    create_transaction(name: "Groceries")

    assert_no_difference [ "Rule.count", "Rule::Condition.count", "Rule::Action.count" ] do
      result = @fn.call(definition)

      assert_nil result[:error], result.inspect
      assert_equal 1, result[:preview][:match_count]
      assert_equal [ entry.entryable.id ], result[:preview][:sample].map { |t| t[:id] }
      assert_equal @category.name_with_parent, result[:preview][:actions].first[:value_name]
      assert_nil result[:preview][:preview_token], "an unsaved definition gets no token"
    end

    assert_nil entry.entryable.reload.category_id
  end

  test "previews a saved rule and issues a token" do
    create_transaction(name: "ZXQ Coffee Shop")
    rule = @family.rules.create!(resource_type: "transaction", **rule_attributes)

    result = @fn.call("rule_id" => rule.id)

    assert_equal 1, result[:preview][:match_count]
    assert result[:preview][:preview_token].present?
  end

  test "respects effective_date and compound or conditions" do
    create_transaction(name: "ZXQ Coffee Shop", date: 10.days.ago.to_date)
    create_transaction(name: "ZXQ Tea House", date: 2.days.ago.to_date)
    create_transaction(name: "ZXQ Bakery", date: 2.days.ago.to_date)

    params = definition(conditions: [
      { "condition_type" => "compound", "operator" => "or", "sub_conditions" => [
        { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" },
        { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq tea" }
      ] }
    ])

    assert_equal 2, @fn.call(params)[:preview][:match_count]
    assert_equal 1, @fn.call(params.merge("effective_date" => 5.days.ago.to_date.iso8601))[:preview][:match_count]
  end

  test "uses the fork's operators: tag not equal to and starts with" do
    tagged = create_transaction(name: "ZXQ Coffee Shop", tags: [ tags(:one) ])
    untagged = create_transaction(name: "ZXQ Coffee Bar")

    not_tagged = @fn.call(definition(conditions: [
      { "condition_type" => "transaction_name", "operator" => "starts_with", "value" => "zxq" },
      { "condition_type" => "transaction_tag", "operator" => "!=", "value" => tags(:one).id }
    ]))

    assert_nil not_tagged[:error], not_tagged.inspect
    assert_equal [ untagged.entryable.id ], not_tagged[:preview][:sample].map { |t| t[:id] }
    assert_not_includes not_tagged[:preview][:sample].map { |t| t[:id] }, tagged.entryable.id
  end

  test "rejects invalid definitions with every problem listed" do
    result = @fn.call(definition(
      conditions: [
        { "condition_type" => "transaction_amount", "operator" => "like", "value" => "5" },
        { "condition_type" => "transaction_category", "operator" => "=", "value" => SecureRandom.uuid }
      ],
      actions: [ { "action_type" => "auto_categorize" } ]
    ))

    assert_equal "invalid_rule", result[:error]
    assert_equal 3, result[:problems].size
  end

  test "rejects nested compound conditions and non-numeric amounts" do
    nested = @fn.call(definition(conditions: [
      { "condition_type" => "compound", "operator" => "and", "sub_conditions" => [
        { "condition_type" => "compound", "operator" => "or", "sub_conditions" => [] }
      ] }
    ]))
    assert_match "cannot be nested", nested[:problems].first

    amount = @fn.call(definition(conditions: [ { "condition_type" => "transaction_amount", "operator" => ">", "value" => "abc" } ]))
    assert_match "must be a number", amount[:problems].first
  end

  test "requires exactly one of rule_id or a definition" do
    assert_equal "invalid_arguments", @fn.call({})[:error]

    rule = @family.rules.create!(resource_type: "transaction", **rule_attributes)
    assert_equal "invalid_arguments", @fn.call(definition.merge("rule_id" => rule.id))[:error]
  end

  test "refuses another family's rule" do
    foreign = families(:empty).rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )

    assert_equal "not_found", @fn.call("rule_id" => foreign.id)[:error]
  end

  test "a zero sample issues no token when there are matches" do
    create_transaction(name: "ZXQ Coffee Shop")
    rule = @family.rules.create!(resource_type: "transaction", **rule_attributes)

    preview = @fn.call("rule_id" => rule.id, "sample_size" => 0)[:preview]

    assert_equal 1, preview[:match_count]
    assert_nil preview[:preview_token]
  end

  private
    def definition(conditions: nil, actions: nil)
      {
        "conditions" => conditions || [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" } ],
        "actions" => actions || [ { "action_type" => "set_transaction_category", "value" => @category.id } ]
      }
    end

    def rule_attributes
      {
        conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
        actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
      }
    end
end
