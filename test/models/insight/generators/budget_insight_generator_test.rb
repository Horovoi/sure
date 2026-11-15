require "test_helper"

# Fiscal months that start on the 5th: the March period runs from 5 March to 4 April
class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    @category = categories(:food_and_drink)
  end

  test "a category over its limit gives a high-priority warning for the fiscal month" do
    travel_to Date.new(2026, 3, 20) do
      budget = set_up_budget(category_limit: 100)
      create_transaction(account: accounts(:depository), amount: 150, category: @category, date: Date.new(2026, 3, 10))

      insights = generate

      assert_equal 1, insights.size
      insight = insights.sole
      assert_equal "budget_at_risk", insight.kind
      assert_equal "budget_at_risk.over", insight.template_key
      assert_equal "high", insight.priority
      assert_equal Date.new(2026, 3, 5), insight.period_start
      assert_includes insight.facts[:categories], @category.name
      assert_equal budget.to_param, insight.metadata[:budget_param]
    end
  end

  test "spending before the 5th belongs to the period that started the month before" do
    travel_to Date.new(2026, 3, 3) do
      set_up_budget(category_limit: 100)
      create_transaction(account: accounts(:depository), amount: 150, category: @category, date: Date.new(2026, 2, 20))

      assert_equal Date.new(2026, 2, 5), generate.sole.period_start
    end
  end

  test "a budget within its limits past mid-period is on track" do
    travel_to Date.new(2026, 3, 25) do
      set_up_budget(category_limit: 1_000)
      create_transaction(account: accounts(:depository), amount: 50, category: @category, date: Date.new(2026, 3, 10))

      insight = generate.sole
      assert_equal "budget_on_track", insight.kind
      assert_equal "low", insight.priority
    end
  end

  test "no budget set up gives nothing" do
    travel_to Date.new(2026, 3, 20) do
      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::BudgetInsightGenerator.new(@family).generate
    end

    def set_up_budget(category_limit:)
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
      budget.update!(budgeted_spending: 2_000, expected_income: 3_000)
      budget.budget_categories.find_by!(category: @category).update!(budgeted_spending: category_limit)
      budget.reload
    end
end
