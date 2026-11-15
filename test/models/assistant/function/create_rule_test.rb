require "test_helper"

class Assistant::Function::CreateRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateRule.new(@user)
    @category = categories(:food_and_drink)
  end

  test "is a write tool that names the rule it saved" do
    assert_equal :write, @fn.scope_tag
    assert_not @fn.idempotent?
    assert_equal "Rule", @fn.record_type
  end

  test "saves the rule inactive at the bottom of the list and returns a preview with a token" do
    create_transaction(name: "ZXQ Coffee Shop", amount: 4.5)
    create_transaction(name: "ZXQ Coffee Beans", amount: 25)
    bottom = @family.rules.maximum(:position).to_i

    result = nil
    assert_difference "@family.rules.count", 1 do
      result = @fn.call(
        "name" => "Coffee",
        "conditions" => [
          { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" },
          { "condition_type" => "transaction_amount", "operator" => "<", "value" => "10" }
        ],
        "actions" => [
          { "action_type" => "set_transaction_category", "value" => @category.id },
          { "action_type" => "set_transaction_tags", "value" => [ tags(:one).id, tags(:two).id ] }
        ]
      )
    end

    assert_nil result[:error], result.inspect
    rule = @family.rules.find(result[:id])
    assert_not rule.active
    assert_equal "Coffee", rule.name
    assert_operator rule.position, :>, bottom
    assert_equal 2, rule.conditions.count
    assert_equal [ tags(:one).id, tags(:two).id ].sort, rule.actions.find_by(action_type: "set_transaction_tags").value.split(",").sort
    assert_equal 1, result[:preview][:match_count]
    assert result[:preview][:preview_token].present?
  end

  test "ignores an attempt to create an active rule" do
    result = @fn.call(
      "active" => true,
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    )

    assert_nil result[:error], result.inspect
    assert_not @family.rules.find(result[:id]).active
  end

  test "does not save an invalid rule" do
    assert_no_difference "Rule.count" do
      result = @fn.call(
        "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
        "actions" => [
          { "action_type" => "exclude_transaction" },
          { "action_type" => "exclude_transaction" }
        ]
      )

      assert_equal "invalid_rule", result[:error]
    end

    assert_no_difference "Rule.count" do
      assert_equal "invalid_rule", @fn.call("conditions" => [], "actions" => [])[:error]
      assert_equal "invalid_arguments", @fn.call("conditions" => [])[:error]
    end
  end

  test "rejects AI-backed actions and ids from outside the family" do
    other_category = families(:empty).categories.create!(name: "Elsewhere", color: "#000000")

    result = @fn.call(
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
      "actions" => [
        { "action_type" => "auto_detect_merchants" },
        { "action_type" => "set_transaction_category", "value" => other_category.id }
      ]
    )

    assert_equal "invalid_rule", result[:error]
    assert_equal 2, result[:problems].size
  end

  test "accepts every account of the family, the user's own or not" do
    params = {
      "conditions" => [ { "condition_type" => "transaction_account", "operator" => "=", "value" => accounts(:other_asset).id } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    }

    assert_nil Assistant::Function::CreateRule.new(users(:family_member)).call(params)[:error]
  end

  test "a call is audited with the new rule's id" do
    actor = Assistant::ToolInvocation::Actor.new(user: @user, source: "mcp", client_name: "claude-code")
    arguments = {
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    }

    assert_difference "AiToolAudit.count", 1 do
      Assistant::ToolInvocation.call(@fn, arguments, actor: actor)
    end

    audit = AiToolAudit.newest_first.first
    assert_equal "ok", audit.status
    assert_equal "Rule", audit.result_record_type
    assert_equal [ @family.rules.order(:created_at).last.id ], audit.result_record_ids
  end
end
