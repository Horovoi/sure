require "test_helper"

# w3-envelope budget-rollover-moves: the rollover carry is recomputed only by the budget
# page and the budget wizard. The reports and the dashboard read budgets and must stay
# free of writes.
class BudgetRolloverReadsTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family

    current = budgets(:one)
    previous = Budget.find_or_bootstrap(@family, start_date: current.start_date.prev_month)
    previous.update!(budgeted_spending: 1000, expected_income: 0)
    previous.budget_categories.find_by!(category: categories(:subscriptions)).update!(budgeted_spending: 100, rollover_enabled: true)
    Budget.find_or_bootstrap(@family, start_date: current.start_date)
    current.reload.budget_categories.find_by!(category: categories(:subscriptions)).update!(budgeted_spending: 100, rollover_enabled: true)
  end

  test "the dashboard writes no budget rows" do
    assert_no_budget_writes { get root_path }
  end

  test "the reports page writes no budget rows" do
    assert_no_budget_writes { get reports_path }
  end

  test "the budget page does recompute the carry" do
    Budget::RolloverCalculator.any_instance.expects(:recompute!).at_least_once.returns(false)

    get budget_path(budgets(:one))

    assert_response :ok
  end

  private
    def assert_no_budget_writes
      Budget::RolloverCalculator.any_instance.expects(:recompute!).never

      assert_no_difference -> { BudgetCategory.count } do
        assert_no_changes -> { BudgetCategory.maximum(:updated_at) } do
          assert_no_changes -> { BudgetCategory.sum(:rolled_over_amount) } do
            yield
            assert_response :ok
          end
        end
      end
    end
end
