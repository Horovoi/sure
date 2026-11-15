require "test_helper"

class Assistant::Function::CreateGoalTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::CreateGoal.new(@user)
    # A fresh account: fixture goals already claim `depository` in full
    @account = @family.accounts.create!(name: "Trip savings", balance: 2_000, currency: "USD", accountable: Depository.new)
  end

  test "creates a goal with linked accounts in the family currency" do
    result = nil
    assert_difference -> { @family.goals.count } => 1, -> { GoalAccount.count } => 1 do
      result = @function.call(
        "name" => "Trip to Lviv",
        "target_amount" => 1_500,
        "target_date" => Date.new(2027, 3, 1).iso8601,
        "account_ids" => [ @account.id ]
      )
    end

    goal = Goal.find(result[:id])
    assert result[:created]
    assert_equal "Trip to Lviv", goal.name
    assert_equal "one_off", goal.kind
    assert_equal @family.primary_currency_code, goal.currency
    assert_equal BigDecimal("1500"), goal.target_amount.to_d
    assert_equal [ @account ], goal.linked_accounts.to_a
    assert_equal "/goals/#{goal.id}", result.dig(:goal, :url)
  end

  test "refuses another family's account" do
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 100, currency: "USD", accountable: Depository.new)

    result = nil
    assert_no_difference -> { Goal.count } do
      result = @function.call("name" => "X", "target_amount" => 100, "account_ids" => [ other.id ])
    end

    assert_equal "account_not_found", result[:error]
    assert_equal [ other.id ], result[:unknown_account_ids]
    assert_not_includes result[:available_accounts].map { |account| account[:id] }, other.id
  end

  test "an account claimed in full by another goal needs an earmark" do
    claimed = accounts(:depository)

    result = @function.call("name" => "Holiday", "target_amount" => 1_000, "account_ids" => [ claimed.id ])
    assert_equal "account_claimed_in_full", result[:error]
    assert_equal [ claimed.id ], result[:claimed_account_ids]

    result = @function.call("name" => "Holiday", "target_amount" => 1_000, "account_ids" => [ claimed.id ],
                            "earmarks" => { claimed.id => 500 })
    assert result[:created]
    assert_equal BigDecimal("500"), Goal.find(result[:id]).goal_accounts.sole.allocated_amount.to_d
  end

  test "a reserve sized in months of expenses takes its target from the median spend" do
    Goal.any_instance.stubs(:median_monthly_expense).returns(BigDecimal("500"))

    result = @function.call("name" => "Emergency", "kind" => "maintained", "target_months" => 6, "account_ids" => [ @account.id ])

    goal = Goal.find(result[:id])
    assert_equal "maintained", goal.kind
    assert_equal "months_of_expenses", goal.target_mode
    assert_equal 6, goal.target_months
    assert_equal BigDecimal("3000"), goal.target_amount.to_d
  end

  test "target_months is only for reserves" do
    result = @function.call("name" => "Trip", "target_months" => 3, "account_ids" => [ @account.id ])

    assert_equal "target_months_needs_reserve", result[:error]
  end

  test "soft errors name what to fix" do
    assert_equal "invalid_name", @function.call("target_amount" => 100, "account_ids" => [ @account.id ])[:error]
    assert_equal "invalid_target_amount", @function.call("name" => "X", "target_amount" => 0, "account_ids" => [ @account.id ])[:error]

    no_accounts = @function.call("name" => "X", "target_amount" => 100, "account_ids" => [])
    assert_equal "no_accounts", no_accounts[:error]
    assert(no_accounts[:available_accounts].any? { |account| account[:id] == @account.id })
  end

  test "is a write tool: not read-only, not destructive" do
    assert_equal :write, Assistant::Function::CreateGoal.scope_tag
    assert_equal({ read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false },
      @function.mcp_annotations)
  end

  test "a create_goal call writes one audit row with the new goal's id" do
    actor = Assistant::ToolInvocation::Actor.new(user: @user, source: "mcp", client_name: "claude-code")

    result = nil
    assert_difference -> { AiToolAudit.count }, 1 do
      result = Assistant::ToolInvocation.call(@function, { "name" => "Audited", "target_amount" => 100, "account_ids" => [ @account.id ] }, actor: actor)
    end

    audit = AiToolAudit.order(:created_at).last
    assert_equal "create_goal", audit.tool_name
    assert_equal "write", audit.scope_tag
    assert_equal "ok", audit.status
    assert_equal "Goal", audit.result_record_type
    assert_equal [ result[:id] ], audit.result_record_ids
  end
end
