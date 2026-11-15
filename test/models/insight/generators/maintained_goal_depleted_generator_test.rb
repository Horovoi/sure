require "test_helper"

class Insight::Generators::MaintainedGoalDepletedGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
  end

  test "a reserve below its level gives one high-priority insight for the fiscal month" do
    travel_to Date.new(2026, 3, 20) do
      goal = reserve(name: "Precaution", balance: 4_000, target: 6_000)

      insight = generate.sole
      assert_equal "maintained_goal_depleted", insight.kind
      assert_equal "high", insight.priority
      assert_equal goal.id, insight.dedupe_key
      assert_equal goal.id, insight.metadata[:goal_id]
      assert_equal Date.new(2026, 3, 5), insight.period_start
      assert_equal "Precaution", insight.facts[:goal]
    end
  end

  test "a second run adds no insight" do
    travel_to Date.new(2026, 3, 20) do
      reserve(name: "Precaution", balance: 4_000, target: 6_000)
      Insight::GeneratorRegistry.stubs(:generators).returns([ Insight::Generators::MaintainedGoalDepletedGenerator ])

      assert_difference -> { @family.insights.where(kind: "maintained_goal_depleted").count }, 1 do
        GenerateInsightsJob.perform_now(@family)
        GenerateInsightsJob.perform_now(@family)
      end

      insight = @family.insights.find_by!(kind: "maintained_goal_depleted")
      assert_equal "Precaution has dropped below its level", insight.title
      assert_match "It is", insight.body
    end
  end

  test "a reserve at its level, a paused reserve and a one-off goal give nothing" do
    travel_to Date.new(2026, 3, 20) do
      reserve(name: "Whole", balance: 6_000, target: 6_000)
      reserve(name: "Shelved", balance: 1_000, target: 6_000).pause!
      @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |goal|
        goal.goal_accounts.build(account: fresh_account(0))
      end

      assert_empty generate
    end
  end

  test "at most two, the largest shortfall first" do
    travel_to Date.new(2026, 3, 20) do
      reserve(name: "Small gap", balance: 5_000, target: 6_000)
      big = reserve(name: "Big gap", balance: 1_000, target: 9_000)
      middle = reserve(name: "Middle gap", balance: 3_000, target: 6_000)

      assert_equal [ big.id, middle.id ], generate.map(&:dedupe_key)
    end
  end

  private
    def generate
      Insight::Generators::MaintainedGoalDepletedGenerator.new(@family).generate
    end

    # A fresh account each time: fixture goals already claim `depository`
    def fresh_account(balance)
      @family.accounts.create!(name: "Pot #{SecureRandom.hex(4)}", balance: balance, currency: "USD", accountable: Depository.new)
    end

    def reserve(name:, balance:, target:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD", kind: "maintained") do |goal|
        goal.goal_accounts.build(account: fresh_account(balance))
      end
    end
end
