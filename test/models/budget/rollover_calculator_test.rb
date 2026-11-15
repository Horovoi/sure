require "test_helper"

class Budget::RolloverCalculatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @currency = @family.currency
    @holiday = @family.categories.create!(name: "Rollover Holiday", classification: "expense", color: "#4da568", lucide_icon: "plane")
    @march = Date.new(2026, 3, 1)
    @april = Date.new(2026, 4, 1)
    @may = Date.new(2026, 5, 1)
  end

  test "an envelope with rollover on carries its leftover into the next period" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100)
      spend(30, on: @march + 5)

      assert recompute!

      assert_equal 70, stored_carry(april)
      assert_equal 0, stored_carry(march)
    end
  end

  test "the carry adds up over several periods and counts in what is left to spend" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      may = period_budget(@may)
      [ march, april, may ].each { |budget| envelope(budget, @holiday, budgeted: 100) }
      spend(30, on: @march + 5)
      spend(50, on: @april + 5)

      recompute!

      assert_equal 70, stored_carry(april)
      assert_equal 120, stored_carry(may)

      may_row = Budget.find(may.id).budget_categories.find { |bc| bc.category_id == @holiday.id }
      assert_equal 220, may_row.available_to_spend
      assert_equal 120, may_row.rolled_over_amount
      assert may_row.rolled_over?
    end
  end

  test "an overspent period carries 0, never a debt" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100)
      spend(140, on: @march + 5)

      recompute!

      assert_equal 0, stored_carry(april)
      assert_equal 100, Budget.find(april.id).budget_categories.find { |bc| bc.category_id == @holiday.id }.available_to_spend
    end
  end

  test "a period with rollover off sends nothing and receives nothing" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      may = period_budget(@may)
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100, rollover: false)
      envelope(may, @holiday, budgeted: 100)

      recompute!

      assert_equal 0, stored_carry(april)
      assert_equal 0, stored_carry(may), "April's surplus was given up with rollover off"
    end
  end

  test "switching rollover off clears the stored carry" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      envelope(march, @holiday, budgeted: 100)
      april_row = envelope(april, @holiday, budgeted: 100)
      recompute!
      assert_equal 100, stored_carry(april)

      april_row.update!(rollover_enabled: false)
      BudgetCategory.where(budget: march).update_all(rollover_enabled: false)
      recompute!

      assert_equal 0, stored_carry(april)
      assert_equal 0, april_row.reload.rolled_over_amount
    end
  end

  test "a period never set up is a gap the carry crosses" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      period_budget(@april, amount: nil)
      may = period_budget(@may)
      envelope(march, @holiday, budgeted: 100)
      envelope(may, @holiday, budgeted: 100)
      spend(40, on: @march + 5)

      recompute!

      assert_equal 60, stored_carry(may)
    end
  end

  test "a parent's carry leaves out its ring-fenced subcategories, which carry their own" do
    travel_to Date.new(2026, 6, 15) do
      flights = @family.categories.create!(name: "Rollover Flights", parent: @holiday, classification: "expense")
      march = period_budget(@march)
      april = period_budget(@april)
      [ march, april ].each do |budget|
        envelope(budget, @holiday, budgeted: 300)
        envelope(budget, flights, budgeted: 100)
      end
      spend(20, on: @march + 5)
      spend(60, on: @march + 6, category: flights)

      recompute!

      # Parent: 300 - 100 (flights) = 200 own, spent 80 - 60 = 20 own, carries 180
      assert_equal 180, stored_carry(april)
      assert_equal 40, stored_carry(april, flights)

      parent = Budget.find(april.id).budget_categories.find { |bc| bc.category_id == @holiday.id }
      assert_equal 220, parent.display_rolled_over_amount
      assert_equal 520, parent.available_to_spend
    end
  end

  test "a shared subcategory has no carry of its own" do
    travel_to Date.new(2026, 6, 15) do
      hotels = @family.categories.create!(name: "Rollover Hotels", parent: @holiday, classification: "expense")
      march = period_budget(@march)
      april = period_budget(@april)
      [ march, april ].each do |budget|
        envelope(budget, @holiday, budgeted: 100)
        envelope(budget, hotels, budgeted: 0)
      end

      recompute!

      assert_equal 0, stored_carry(april, hotels)
      shared = Budget.find(april.id).budget_categories.find { |bc| bc.category_id == hotels.id }
      assert_equal 0, shared.rolled_over_amount
      assert_equal 100, shared.display_rolled_over_amount, "it shows its parent's carry"
    end
  end

  test "the carry stops at a currency change" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100)
      BudgetCategory.where(budget: march).update_all(currency: "EUR")

      recompute!

      assert_equal 0, stored_carry(april)
    end
  end

  test "fiscal months: the carry follows the fiscal periods" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)

    travel_to Date.new(2026, 6, 15) do
      march = period_budget(Date.new(2026, 3, 25), end_date: Date.new(2026, 4, 24))
      april = period_budget(Date.new(2026, 4, 25), end_date: Date.new(2026, 5, 24))
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100)
      # In the March period although in the April calendar month
      spend(30, on: Date.new(2026, 4, 10))
      # In the April period: not March's spending
      spend(25, on: Date.new(2026, 4, 26))

      recompute!

      assert_equal 70, stored_carry(april)
    end
  end

  test "a family that never turned rollover on writes nothing" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      envelope(march, @holiday, budgeted: 100, rollover: false)

      assert_no_changes -> { BudgetCategory.maximum(:updated_at) } do
        assert_not recompute!
      end
    end
  end

  test "an unchanged chain is not walked again" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    travel_to Date.new(2026, 6, 15) do
      settled_chain

      Budget::RolloverCalculator.any_instance.expects(:recompute_chain!).never
      recompute!
    end
  end

  test "new spending recomputes a settled chain" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    travel_to Date.new(2026, 6, 15) do
      april = settled_chain.last

      spend(30, on: @march + 5)
      recompute!

      assert_equal 70, stored_carry(april)
    end
  end

  test "an allocation written behind an older timestamp recomputes a settled chain" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    travel_to Date.new(2026, 6, 15) do
      march, april = settled_chain

      BudgetCategory.where(budget: march, category: @holiday).update_all(budgeted_spending: 40, updated_at: 1.day.ago)
      recompute!

      assert_equal 40, stored_carry(april)
    end
  end

  test "the read and the write hold the chain's advisory lock" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      envelope(march, @holiday, budgeted: 100)

      statements = []
      callback = ->(*args) { statements << args.last[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { recompute! }

      assert statements.any? { |sql| sql.include?("pg_advisory_xact_lock") }
    end
  end

  test "the budget page reads go through the calculator, find_or_bootstrap does not" do
    travel_to Date.new(2026, 6, 15) do
      Budget::RolloverCalculator.any_instance.expects(:recompute!).never
      Budget.find_or_bootstrap(@family, start_date: @april)
    end
  end

  test "a new period takes the rollover choice of the last set-up budget" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      envelope(march, @holiday, budgeted: 100)

      april = Budget.find_or_bootstrap(@family, start_date: @april)

      assert april.all_budget_categories.find_by!(category: @holiday).rollover_enabled?
    end
  end

  test "a rollover choice reaches the later periods that exist already" do
    travel_to Date.new(2026, 6, 15) do
      march = period_budget(@march)
      april = period_budget(@april)
      march_row = envelope(march, @holiday, budgeted: 100, rollover: false)
      april_row = envelope(april, @holiday, budgeted: 100, rollover: false)

      march_row.update!(rollover_enabled: true)
      march_row.propagate_rollover_choice_forward!

      assert april_row.reload.rollover_enabled?
    end
  end

  private
    def period_budget(start_date, amount: 1000, end_date: start_date.end_of_month)
      @family.budgets.create!(start_date: start_date, end_date: end_date, budgeted_spending: amount, expected_income: 0, currency: @currency)
    end

    def envelope(budget, category, budgeted:, rollover: true)
      budget.all_budget_categories.create!(category: category, budgeted_spending: budgeted, currency: @currency, rollover_enabled: rollover)
    end

    def spend(amount, on:, category: @holiday)
      create_transaction(account: accounts(:depository), date: on, amount: amount, currency: @currency, category: category, name: "Rollover spending")
    end

    def recompute!
      Budget::RolloverCalculator.new(family: Family.find(@family.id)).recompute!
    end

    def stored_carry(budget, category = @holiday)
      BudgetCategory.find_by!(budget: budget, category: category)[:rolled_over_amount]
    end

    # March and April at 100 each, recomputed until a pass changes nothing
    def settled_chain
      march = period_budget(@march)
      april = period_budget(@april)
      envelope(march, @holiday, budgeted: 100)
      envelope(april, @holiday, budgeted: 100)
      recompute!
      recompute!
      [ march, april ]
    end
end
