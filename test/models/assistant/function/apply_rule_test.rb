require "test_helper"

class Assistant::Function::ApplyRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::ApplyRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "is a destructive tool that is not idempotent" do
    assert_equal :destructive, @fn.scope_tag
    assert_not @fn.idempotent?
    assert @fn.mcp_annotations[:destructive_hint]
  end

  test "the chat and both MCP scopes get every rule tool" do
    names = Assistant.config_for(chats(:one))[:functions].map(&:name)

    %w[get_rules get_rule_options preview_rule create_rule update_rule apply_rule].each do |name|
      assert_includes names, name
      assert_includes Assistant.function_classes_for(:full).map(&:name), name
    end
  end

  test "activates and runs the rule with a token from its preview, and names the RuleRun and the changed rows" do
    entries = [ create_transaction(name: "ZXQ Coffee Shop"), create_transaction(name: "ZXQ Coffee Bar") ]
    preview = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id)[:preview]

    result = nil
    assert_difference -> { @rule.rule_runs.count }, 1 do
      result = @fn.call("rule_id" => @rule.id, "preview_token" => preview[:preview_token])
    end

    assert_nil result[:error], result.inspect
    assert @rule.reload.active
    entries.each { |entry| assert_equal @category, entry.entryable.reload.category }

    run = @rule.rule_runs.recent.first
    assert_equal run.id, result[:rule_run_id]
    assert_equal "success", run.status
    assert_equal "manual", run.execution_type
    assert_equal preview[:match_count], result[:ids].size, "the preview count equals the rows the apply changed"
    assert_equal entries.map { |e| e.entryable.id }.sort, result[:ids].sort
    assert_equal [ run.id ], @fn.audit_refs(result)
  end

  test "the audit row names the RuleRun and keeps the matches from before" do
    entry = create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    actor = Assistant::ToolInvocation::Actor.new(user: @user, source: "mcp", client_name: "claude-code")

    Assistant::ToolInvocation.call(@fn, { "rule_id" => @rule.id, "preview_token" => token }, actor: actor)

    audit = AiToolAudit.newest_first.first
    assert_equal "apply_rule", audit.tool_name
    assert_equal "ok", audit.status
    assert_equal "RuleRun", audit.result_record_type
    assert_equal [ @rule.rule_runs.recent.first.id ], audit.result_record_ids
    assert_equal [ entry.entryable.id ], audit.audit_before["transactions"].map { |t| t["id"] }
    assert_nil audit.audit_before["transactions"].first["category_id"]
  end

  test "the match count from get_rules alone cannot apply a rule" do
    create_transaction(name: "ZXQ Coffee Shop")
    match_count = Assistant::Function::GetRules.new(@user).call("rule_id" => @rule.id)[:rule][:match_count]
    assert_equal 1, match_count

    [ nil, "", match_count.to_s, "forged--token" ].each do |token|
      assert_no_difference "RuleRun.count" do
        assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
      end
    end
    assert_not @rule.reload.active
  end

  test "a rule matching nothing can be activated for future transactions" do
    preview = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id)[:preview]
    assert_equal 0, preview[:match_count]

    result = @fn.call("rule_id" => @rule.id, "preview_token" => preview[:preview_token])

    assert_nil result[:error], result.inspect
    assert @rule.reload.active
    assert_empty result[:ids]
  end

  test "refuses a token once the matches change, and returns a fresh one" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    create_transaction(name: "ZXQ Coffee Bar")

    result = nil
    assert_no_difference("RuleRun.count") { result = @fn.call("rule_id" => @rule.id, "preview_token" => token) }

    assert_equal "preview_stale", result[:error]
    assert_equal 2, result[:preview][:match_count]
    assert_not @rule.reload.active

    assert_nil @fn.call("rule_id" => @rule.id, "preview_token" => result[:preview][:preview_token])[:error]
  end

  test "refuses a token for another definition, even with the same match count" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    Assistant::Function::UpdateRule.new(@user).call(
      "rule_id" => @rule.id,
      "actions" => [ { "action_type" => "set_transaction_category", "value" => categories(:income).id } ]
    )

    assert_equal "preview_stale", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    assert_not @rule.reload.active
  end

  test "refuses an expired token, another rule's token and another user's token" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token

    other_rule = @family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
    assert_equal "preview_required", @fn.call("rule_id" => other_rule.id, "preview_token" => token)[:error]

    assert_equal "preview_required",
      Assistant::Function::ApplyRule.new(users(:family_member)).call("rule_id" => @rule.id, "preview_token" => token)[:error]

    travel Assistant::Function::RuleSupport::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    end
  end

  test "keeps values the user set by hand, even with override_locked" do
    entry = create_transaction(name: "ZXQ Coffee Shop")
    entry.entryable.lock_attr!(:category_id)

    result = @fn.call("rule_id" => @rule.id, "preview_token" => preview_token, "override_locked" => true)

    assert_nil result[:error], result.inspect
    assert_nil entry.entryable.reload.category_id
    assert_empty result[:ids], "a matched row the lock kept is not reported as changed"
    assert_equal 1, result[:matched_count]
  end

  test "an active rule higher up wins the field it sets" do
    entry = create_transaction(name: "ZXQ Coffee Shop")
    higher = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: categories(:income).id } ]
    )
    Rule.update_positions!(@family, [ higher.id ] + (@family.rules.ordered.pluck(:id) - [ higher.id ]))

    result = @fn.call("rule_id" => @rule.id, "preview_token" => preview_token)

    assert_nil result[:error], result.inspect
    assert_equal categories(:income), entry.entryable.reload.category
    assert_equal 1, result[:other_rule_run_ids].size
  end

  test "queues the run when the family's rules are already running" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    Rule::Runner.any_instance.stubs(:run).raises(Rule::Runner::LockBusy)

    result = nil
    assert_enqueued_with(job: ApplyRulesJob) do
      result = @fn.call("rule_id" => @rule.id, "preview_token" => token)
    end

    assert result[:queued]
    assert @rule.reload.active
  end

  test "refuses rules with AI-backed actions, unknown ids and another family's rules" do
    foreign = families(:empty).rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )
    assert_equal "not_found", @fn.call("rule_id" => foreign.id, "preview_token" => "x")[:error]
    assert_not foreign.reload.active
    assert_equal "not_found", @fn.call("rule_id" => "nope", "preview_token" => "x")[:error]

    @rule.actions.create!(action_type: "auto_categorize")
    assert_equal "ai_action", @fn.call("rule_id" => @rule.reload.id, "preview_token" => "x")[:error]
  end

  private
    def preview_token
      token = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id)[:preview][:preview_token]
      assert token, "a preview of a saved rule should issue a token"
      token
    end
end
