require "test_helper"

class Assistant::Function::GetBudgetTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @tool = Assistant::Function::GetBudget.new(@user)

    # Fresh categories, so fixture transactions do not change the figures under test
    @groceries = @family.categories.create!(name: "Budget Tool Groceries", color: "#4da568", lucide_icon: "carrot", classification: "expense")
    @market = @family.categories.create!(name: "Budget Tool Market", parent: @groceries, color: "#4da568", lucide_icon: "store", classification: "expense")
  end

  test "is a read tool whose month argument is optional over MCP" do
    assert_equal :read, @tool.scope_tag
    assert Assistant::Function::GetBudget.read_only?
    assert_empty @tool.mcp_input_schema[:required]
    assert_includes Assistant.function_classes, Assistant::Function::GetBudget
  end

  test "returns the current period with the total and each category's budgeted, actual and available amounts" do
    travel_to Date.new(2026, 11, 15) do
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
      budget.update!(budgeted_spending: 1000, expected_income: 2000)
      budget.budget_categories.find_by!(category: @groceries).update!(budgeted_spending: 400)
      create_transaction(category: @groceries, amount: 150, date: Date.new(2026, 11, 10))
      create_transaction(category: @market, amount: 20, date: Date.new(2026, 11, 11))

      result = @tool.call({})

      assert_equal @family.currency, result[:currency]
      assert_equal budget.to_param, result[:month]
      assert_equal({ start_date: "2026-11-01", end_date: "2026-11-30" }, result[:period])
      assert result[:is_current]
      assert_equal 16, result[:days_left]
      assert result[:initialized]
      assert_equal 1000.0, result[:totals][:budgeted_spending]
      assert_equal 2000.0, result[:income][:expected_income]

      row = result[:categories].find { |category| category[:category_id] == @groceries.id }
      assert_equal budget.budget_categories.find_by!(category: @groceries).id, row[:id]
      assert_equal 400.0, row[:budgeted]
      assert_equal 170.0, row[:actual], "a parent's spending includes its subcategories"
      assert_equal 230.0, row[:available]
      assert_equal "on_track", row[:status]

      sub = row[:subcategories].find { |category| category[:category_id] == @market.id }
      assert sub[:inherits_parent_budget]
      assert_equal 20.0, sub[:actual]
      assert_equal 400.0, sub[:budgeted], "an inheriting subcategory shows its parent's amount"
    end
  end

  test "a period with no total yet reads as not initialized" do
    travel_to Date.new(2026, 11, 15) do
      result = @tool.call("month" => "2027-02")

      assert_equal false, result[:initialized]
      assert_equal "not_set_up", result[:allocation_state]
      assert_nil result[:totals][:budgeted_spending]
      assert_equal false, result[:is_current]
      assert_not result.key?(:days_left)
    end
  end

  test "fiscal day 25: a date before the boundary is in the period that started last month" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)
    create_transaction(category: @groceries, amount: 40, date: Date.new(2026, 11, 24))
    create_transaction(category: @groceries, amount: 30, date: Date.new(2026, 11, 25))

    travel_to Date.new(2026, 11, 24) do
      result = @tool.call({})

      assert_equal({ start_date: "2026-10-25", end_date: "2026-11-24" }, result[:period])
      assert_equal "oct-2026", result[:month]
      assert_equal 1, result[:days_left]
      assert_equal 40.0, groceries_row(result)[:actual]
    end
  end

  test "fiscal day 25: a date on the boundary starts the new period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)
    create_transaction(category: @groceries, amount: 40, date: Date.new(2026, 11, 24))
    create_transaction(category: @groceries, amount: 30, date: Date.new(2026, 11, 25))

    travel_to Date.new(2026, 11, 25) do
      result = @tool.call({})

      assert_equal({ start_date: "2026-11-25", end_date: "2026-12-24" }, result[:period])
      assert_equal "nov-2026", result[:month]
      assert_equal 30.0, groceries_row(result)[:actual]
    end
  end

  test "fiscal day 25: a month names the period that starts in it, a date the period that contains it" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    travel_to Date.new(2026, 11, 15) do
      assert_equal({ start_date: "2026-03-25", end_date: "2026-04-24" }, @tool.call("month" => "2026-03")[:period])
      assert_equal({ start_date: "2026-03-25", end_date: "2026-04-24" }, @tool.call("month" => "Mar-2026")[:period])
      assert_equal({ start_date: "2026-02-25", end_date: "2026-03-24" }, @tool.call("month" => "2026-03-10")[:period])
      assert_equal({ start_date: "2026-03-25", end_date: "2026-04-24" }, @tool.call("month" => "2026-03-25")[:period])
    end
  end

  test "an unreadable or out-of-range month returns error data and creates no budget" do
    travel_to Date.new(2026, 11, 15) do
      assert_no_difference -> { Budget.count } do
        assert_equal "invalid_month", @tool.call("month" => "2026-13")[:error]
        assert_equal "invalid_month", @tool.call("month" => "next month")[:error]
        assert_equal "invalid_month", @tool.call("month" => "2026-02-30")[:error]
        assert_equal "month_out_of_range", @tool.call("month" => "2031-01")[:error]
      end
    end
  end

  test "spending with no category shows as the uncategorized row" do
    travel_to Date.new(2026, 11, 15) do
      Budget.find_or_bootstrap(@family, start_date: Date.current).update!(budgeted_spending: 1000, expected_income: 0)
      create_transaction(category: nil, amount: 55, date: Date.new(2026, 11, 3))

      uncategorized = @tool.call({})[:uncategorized]

      assert uncategorized
      assert_operator uncategorized[:actual], :>=, 55.0
    end
  end

  # w3-envelope budget-rollover-moves
  test "returns each category's rollover choice and carried amount" do
    travel_to Date.new(2026, 11, 15) do
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
      budget.update!(budgeted_spending: 1000, expected_income: 0)
      budget.budget_categories.find_by!(category: @groceries).update_columns(budgeted_spending: 400, rollover_enabled: true, rolled_over_amount: 60)

      result = @tool.call({})
      groceries = result[:categories].find { |row| row[:category_id] == @groceries.id }

      assert groceries[:rollover_enabled]
      assert_equal 60.0, groceries[:rolled_over_amount]
      assert_equal 460.0, groceries[:available]
      assert_equal 400.0, groceries[:budgeted]
      assert_equal 60.0, result[:totals][:rolled_over]
      assert_equal false, groceries[:subcategories].first[:rollover_enabled]
    end
  end

  private
    def groceries_row(result)
      result[:categories].find { |category| category[:category_id] == @groceries.id }
    end
end
