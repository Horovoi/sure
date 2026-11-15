require "test_helper"

class Assistant::Function::UpdateRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::UpdateRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      name: "Coffee",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "is a write tool" do
    assert_equal :write, @fn.scope_tag
    assert_equal "Rule", @fn.record_type
  end

  test "renaming keeps an active rule active" do
    result = @fn.call("rule_id" => @rule.id, "name" => "Morning coffee")

    assert_nil result[:error], result.inspect
    assert_equal @rule.id, result[:id]
    assert_equal "Morning coffee", @rule.reload.name
    assert @rule.active
  end

  test "replacing the definition deactivates the rule and returns a fresh preview with a token" do
    create_transaction(name: "ZXQ Tea House")

    result = @fn.call(
      "rule_id" => @rule.id,
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq tea" } ]
    )

    assert_nil result[:error], result.inspect
    @rule.reload
    assert_not @rule.active
    assert_equal [ "zxq tea" ], @rule.conditions.map(&:value)
    assert_equal 1, @rule.actions.count, "actions were not passed, so they stay"
    assert_equal 1, result[:preview][:match_count]
    assert result[:preview][:preview_token].present?
  end

  test "deactivates but never activates" do
    assert_equal "cannot_activate", @fn.call("rule_id" => @rule.id, "active" => true)[:error]

    assert_nil @fn.call("rule_id" => @rule.id, "active" => false)[:error]
    assert_not @rule.reload.active
  end

  test "keeps the rule unchanged when the new definition is invalid" do
    result = @fn.call("rule_id" => @rule.id, "actions" => [ { "action_type" => "set_transaction_category", "value" => SecureRandom.uuid } ])

    assert_equal "invalid_rule", result[:error]
    assert @rule.reload.active
    assert_equal @category.id, @rule.actions.first.value
  end

  test "refuses empty calls, unknown ids, another family's rule and AI rules' definitions" do
    assert_equal "no_changes", @fn.call("rule_id" => @rule.id)[:error]
    assert_equal "not_found", @fn.call("rule_id" => "nope", "name" => "x")[:error]

    foreign = families(:empty).rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )
    assert_equal "not_found", @fn.call("rule_id" => foreign.id, "name" => "Mine")[:error]
    assert_nil foreign.reload.name

    @rule.actions.create!(action_type: "auto_categorize")
    assert_equal "ai_action", @fn.call("rule_id" => @rule.id, "conditions" => [])[:error]
  end

  test "audit_before keeps the rule as it was" do
    before = @fn.audit_before("rule_id" => @rule.id)

    @fn.call("rule_id" => @rule.id, "name" => "Renamed", "active" => false)

    assert_equal "Coffee", before[:name]
    assert before[:active]
    assert_equal "zxq coffee", before[:conditions].first[:value]
    assert_nil @fn.audit_before("rule_id" => "nope")
  end
end
