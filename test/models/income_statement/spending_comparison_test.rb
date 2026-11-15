require "test_helper"

class IncomeStatement::SpendingComparisonTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries", classification: "expense", color: "#123456")
    @misc = @family.categories.create!(name: "Misc", classification: "expense", color: "#654321")
  end

  test "an unfinished fiscal month compares the same days so far of earlier fiscal months" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)

    travel_to Date.new(2026, 3, 8) do
      # The history starts on January 5, so the baseline holds the January and February
      # fiscal months
      spend(1, on: Date.new(2026, 1, 5), category: @misc)
      spend(50, on: Date.new(2026, 1, 6))   # day 2 of the January fiscal month
      spend(100, on: Date.new(2026, 2, 6))  # day 2 of the February fiscal month
      spend(1_000, on: Date.new(2026, 2, 20)) # later in February: not in the same days
      spend(90, on: Date.new(2026, 3, 6))

      comparison = comparison_for(Period.custom(start_date: @family.budget_period_start_for(Date.current), end_date: Date.current))

      assert comparison.in_progress?
      assert comparison.comparable?
      assert_equal Date.new(2026, 3, 5), comparison.period.start_date
      assert_equal Date.new(2026, 3, 8), comparison.period.end_date

      row = row_for(comparison, @groceries)
      assert_equal 90, row.total
      # The average of January 5-8 (50) and February 5-8 (100)
      assert_equal 75, row.normal
      assert_equal 15, row.change
    end
  end

  test "a fiscal month start clamped to a short month steps back on each month's own boundary" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)

    travel_to Date.new(2026, 12, 2) do
      # The history starts on September 30, so the baseline holds two fiscal months
      spend(1, on: Date.new(2026, 9, 30), category: @misc)
      spend(40, on: Date.new(2026, 10, 1))  # day 2 of the fiscal month that starts on Sep 30
      spend(60, on: Date.new(2026, 10, 31)) # day 1 of the fiscal month that starts on Oct 31
      spend(80, on: Date.new(2026, 12, 1))

      start = @family.budget_period_start_for(Date.current)
      assert_equal Date.new(2026, 11, 30), start

      row = row_for(comparison_for(Period.custom(start_date: start, end_date: Date.current)), @groceries)
      assert_equal 80, row.total
      # November window Oct 31 - Nov 2 holds 60; the October window Sep 30 - Oct 2 holds 40
      assert_equal 50, row.normal
    end
  end

  test "refunds in a category are netted against its spending" do
    travel_to Date.new(2026, 3, 20) do
      spend(100, on: Date.new(2026, 3, 2))
      spend(-30, on: Date.new(2026, 3, 3))

      row = row_for(comparison_for(Period.custom(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 10))), @groceries)

      assert_equal 70, row.total
    end
  end

  test "kinds budgets leave out are left out" do
    travel_to Date.new(2026, 3, 20) do
      spend(100, on: Date.new(2026, 3, 2))
      Transaction::BUDGET_EXCLUDED_KINDS.each do |kind|
        spend(500, on: Date.new(2026, 3, 3), kind: kind)
      end

      comparison = comparison_for(Period.custom(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 10)))

      assert_equal 100, row_for(comparison, @groceries).total
      assert_equal 100, comparison.total
    end
  end

  test "excluded kinds do not start the history" do
    travel_to Date.new(2026, 3, 20) do
      spend(500, on: Date.new(2025, 1, 3), kind: "funds_movement")
      spend(100, on: Date.new(2026, 2, 2))

      assert_equal Date.new(2026, 2, 2), IncomeStatement::SpendingComparison.history_start(@family)
    end
  end

  test "a finished period compares with the year before it scaled to its length" do
    travel_to Date.new(2026, 2, 15) do
      (1..12).each { |month| spend(100, on: Date.new(2025, month, 1)) }
      spend(150, on: Date.new(2026, 1, 10))

      comparison = comparison_for(Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31)))

      assert_not comparison.in_progress?
      assert comparison.comparable?
      row = row_for(comparison, @groceries)
      assert_equal 150, row.total
      assert_in_delta 1_200.0 * 31 / 365, row.normal.to_f, 0.01
      assert_equal [ @groceries.id ], comparison.changes.map { |change| change.category.id }
    end
  end

  test "without earlier history there is no normal" do
    travel_to Date.new(2026, 3, 20) do
      spend(100, on: Date.new(2026, 3, 2))

      comparison = comparison_for(Period.custom(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 20)))

      assert_not comparison.comparable?
      assert_nil row_for(comparison, @groceries).normal
      assert_nil comparison.normal_total
      assert_empty comparison.changes
    end
  end

  test "a parent's own spending is listed among its subcategories" do
    fruit = @family.categories.create!(name: "Fruit", classification: "expense", parent: @groceries)

    travel_to Date.new(2026, 3, 20) do
      spend(100, on: Date.new(2026, 3, 2))
      spend(40, on: Date.new(2026, 3, 3), category: fruit)

      row = row_for(comparison_for(Period.custom(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 10))), @groceries)

      assert_equal 140, row.total
      assert_equal [ [ @groceries.id, true, 100 ], [ fruit.id, false, 40 ] ],
        row.subcategories.map { |sub| [ sub.category.id, sub.direct, sub.total ] }
    end
  end

  private
    def spend(amount, on:, kind: "standard", category: @groceries)
      create_transaction(account: @account, currency: @family.currency, amount: amount, date: on, category: category, kind: kind)
    end

    def comparison_for(period)
      IncomeStatement::SpendingComparison.new(
        IncomeStatement.new(@family),
        period: period,
        history_start: IncomeStatement::SpendingComparison.history_start(@family)
      )
    end

    def row_for(comparison, category)
      comparison.rows.find { |row| row.category.id == category.id }
    end
end
