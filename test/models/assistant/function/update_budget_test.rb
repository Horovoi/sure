require "test_helper"

class Assistant::Function::UpdateBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @tool = Assistant::Function::UpdateBudget.new(@user)

    @groceries = @family.categories.create!(name: "Budget Tool Groceries", color: "#4da568", lucide_icon: "carrot", classification: "expense")
    @market = @family.categories.create!(name: "Budget Tool Market", parent: @groceries, color: "#4da568", lucide_icon: "store", classification: "expense")
    @bakery = @family.categories.create!(name: "Budget Tool Bakery", parent: @groceries, color: "#4da568", lucide_icon: "croissant", classification: "expense")
    @transport = @family.categories.create!(name: "Budget Tool Transport", color: "#123456", lucide_icon: "bus", classification: "expense")
    @salary = @family.categories.create!(name: "Budget Tool Salary", color: "#654321", lucide_icon: "briefcase", classification: "income")
  end

  test "is an idempotent write tool that needs only amount" do
    assert_equal :write, @tool.scope_tag
    assert @tool.idempotent?
    assert_equal [ "amount" ], @tool.mcp_input_schema[:required]
    assert_includes Assistant.function_classes, Assistant::Function::UpdateBudget
    assert_not_includes Assistant.function_classes_for(:read), Assistant::Function::UpdateBudget
  end

  test "without a category it sets the budget total and starts expected income at zero" do
    travel_to Date.new(2026, 11, 15) do
      result = @tool.call("month" => "2027-01", "amount" => 3000)

      budget = Budget.find(result[:id])
      assert result[:updated]
      assert_equal "Budget", @tool.record_type
      assert_equal [ budget.id ], @tool.audit_refs(result)
      assert_equal Date.new(2027, 1, 1), budget.start_date
      assert_equal 3000, budget.budgeted_spending
      assert_equal 0, budget.expected_income
      assert_equal "unallocated", result[:totals][:allocation_state]
    end
  end

  test "a total change keeps expected income that is already set" do
    travel_to Date.new(2026, 11, 15) do
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
      budget.update!(budgeted_spending: 1000, expected_income: 4500)

      @tool.call("amount" => "1200.50")

      budget.reload
      assert_equal BigDecimal("1200.5"), budget.budgeted_spending
      assert_equal 4500, budget.expected_income
    end
  end

  test "changes only the named category and returns its budget category id" do
    travel_to Date.new(2026, 11, 15) do
      budget = set_up_budget(Date.current)
      transport_row = budget.budget_categories.find_by!(category: @transport)
      transport_row.update!(budgeted_spending: 150)
      groceries_row = budget.budget_categories.find_by!(category: @groceries)
      other_amounts = budget.all_budget_categories.where.not(id: groceries_row.id).pluck(:id, :budgeted_spending).to_h

      before = @tool.audit_before("category" => @groceries.id, "amount" => 600)
      result = @tool.call("category" => @groceries.id, "amount" => 600)

      assert_equal groceries_row.id, result[:id]
      assert_equal "BudgetCategory", @tool.record_type
      assert_equal 600, groceries_row.reload.budgeted_spending
      assert_equal other_amounts, budget.all_budget_categories.where.not(id: groceries_row.id).pluck(:id, :budgeted_spending).to_h
      assert_equal 2000, budget.reload.budgeted_spending, "the total stays as it was"
      assert_equal 0.0, before[:budgeted_spending]
      assert_equal groceries_row.id, before[:id]
      assert_equal 600.0, result[:budget_category][:budgeted_spending]
    end
  end

  test "finds a category by its name, ignoring case" do
    travel_to Date.new(2026, 11, 15) do
      budget = set_up_budget(Date.current)

      result = @tool.call("category" => "budget tool transport", "amount" => 80)

      assert_equal budget.budget_categories.find_by!(category: @transport).id, result[:id]
      assert_equal 80, budget.budget_categories.find_by!(category: @transport).budgeted_spending
    end
  end

  test "a category amount on a period with no total is refused and leaves no new budget" do
    travel_to Date.new(2026, 11, 15) do
      assert_no_difference -> { Budget.count } do
        result = @tool.call("month" => "2027-03", "category" => @transport.id, "amount" => 50)

        assert_equal "budget_not_set_up", result[:error]
      end
    end
  end

  test "a subcategory edit through the tool raises its parent" do
    travel_to Date.new(2026, 11, 15) do
      budget = set_up_budget(Date.current)
      budget.budget_categories.find_by!(category: @groceries).update!(budgeted_spending: 500)
      budget.budget_categories.find_by!(category: @bakery).update!(budgeted_spending: 200)

      # 500 = 200 (bakery) + 300 reserve; market's 400 is added on top
      result = @tool.call("category" => @market.id, "amount" => 400)

      assert result[:updated]
      assert_not result[:adjusted]
      assert_equal 400, budget.budget_categories.find_by!(category: @market).budgeted_spending
      assert_equal 900, budget.budget_categories.find_by!(category: @groceries).budgeted_spending
      assert_equal 900.0, result[:parent][:budgeted_spending]
      assert_equal 900.0, result[:totals][:allocated_spending]
    end
  end

  test "a parent set below its subcategories through the tool is raised to their sum" do
    travel_to Date.new(2026, 11, 15) do
      budget = set_up_budget(Date.current)
      @tool.call("category" => @market.id, "amount" => 150)
      @tool.call("category" => @bakery.id, "amount" => 100)

      result = @tool.call("category" => @groceries.id, "amount" => 50)

      assert result[:adjusted]
      assert_equal 250.0, result[:budget_category][:budgeted_spending]
      assert_equal 250, budget.budget_categories.find_by!(category: @groceries).budgeted_spending
    end
  end

  test "refuses income, unknown and uncategorized categories" do
    travel_to Date.new(2026, 11, 15) do
      set_up_budget(Date.current)

      assert_equal "not_an_expense_category", @tool.call("category" => @salary.id, "amount" => 10)[:error]
      assert_equal "category_not_found", @tool.call("category" => "No Such Category", "amount" => 10)[:error]
      assert_equal "category_not_found", @tool.call("category" => categories(:one).id, "amount" => 10)[:error], "another family's category"
      assert_equal "uncategorized_not_settable", @tool.call("category" => Category.uncategorized_name, "amount" => 10)[:error]
    end
  end

  test "refuses amounts that are negative, not numbers or too large" do
    travel_to Date.new(2026, 11, 15) do
      [ -1, "abc", nil, "", 10**13, "NaN" ].each do |amount|
        assert_equal "invalid_amount", @tool.call("amount" => amount)[:error], amount.inspect
      end
    end
  end

  test "an invalid month returns error data and writes nothing" do
    travel_to Date.new(2026, 11, 15) do
      assert_no_difference -> { Budget.count } do
        assert_equal "invalid_month", @tool.call("month" => "2026-13", "amount" => 100)[:error]
        assert_equal "invalid_month", @tool.call("month" => "someday", "amount" => 100)[:error]
        assert_equal "month_out_of_range", @tool.call("month" => "2031-01", "amount" => 100)[:error]
      end
    end
  end

  test "fiscal day 25: today before the boundary writes the period that started last month" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    travel_to Date.new(2026, 11, 24) do
      result = @tool.call("amount" => 900)

      budget = Budget.find(result[:id])
      assert_equal [ Date.new(2026, 10, 25), Date.new(2026, 11, 24) ], [ budget.start_date, budget.end_date ]
      assert_equal 900, budget.budgeted_spending
    end
  end

  test "fiscal day 25: a date after the boundary writes the next period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    travel_to Date.new(2026, 11, 24) do
      result = @tool.call("month" => "2026-11-25", "amount" => 700)

      budget = Budget.find(result[:id])
      assert_equal [ Date.new(2026, 11, 25), Date.new(2026, 12, 24) ], [ budget.start_date, budget.end_date ]
      assert_equal "nov-2026", result[:budget][:month]
    end
  end

  test "audit_before is nil for a period with no budget yet and never creates one" do
    travel_to Date.new(2026, 11, 15) do
      assert_no_difference -> { Budget.count } do
        assert_nil @tool.audit_before("month" => "2027-05", "amount" => 100)
      end
    end
  end

  private
    def set_up_budget(date)
      Budget.find_or_bootstrap(@family, start_date: date).tap do |budget|
        budget.update!(budgeted_spending: 2000, expected_income: 0)
      end
    end
end
