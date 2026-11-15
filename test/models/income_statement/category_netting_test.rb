require "test_helper"

class IncomeStatement::CategoryNettingTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @month = Date.new(2024, 2, 1)
    @parent = @family.categories.create!(name: "Shopping", color: "#123456")
    @child = @family.categories.create!(name: "Rebates", parent: @parent)
  end

  test "a refund nets inside its own category" do
    transaction(120, @parent)
    transaction(-20, @parent)

    group = group_for(@parent)

    assert_equal 100, group[:direct]
    assert_equal 100, side_total(group, :expense)
    assert_equal 0, side_total(group, :income)
  end

  test "a child refund is not counted again in its parent" do
    transaction(100, @parent)
    transaction(-30, @child)

    group = group_for(@parent)
    child = group[:children].sole

    assert_equal @child, child[:category]
    assert_equal(-30, child[:net])
    assert_equal 100, group[:direct], "the parent's own net leaves the child out"
    assert_equal 100, side_total(group, :expense)
    assert_equal 30, side_total(group, :income)
  end

  test "uncategorized and other investments have their own keys" do
    transaction(10, nil)
    create_transaction(account: @account, amount: 25, category: nil, date: @month, kind: "investment_contribution")

    assert_equal "uncategorized", IncomeStatement::CategoryNetting.key(Category.uncategorized)
    assert_equal "other_investments", IncomeStatement::CategoryNetting.key(Category.other_investments)
    assert_equal @parent.id.to_s, IncomeStatement::CategoryNetting.key(@parent)

    groups = netting.groups
    uncategorized = groups.find { |group| group[:category].uncategorized? }
    other_investments = groups.find { |group| group[:category].other_investments? }

    # Trades are left out of the totals, so an uncategorized contribution is Uncategorized
    assert_equal 35, uncategorized[:direct]
    assert_equal 0, other_investments[:direct]
    assert_equal 1, groups.count { |group| group[:category].uncategorized? }
    assert_equal 1, groups.count { |group| group[:category].other_investments? }
  end

  test "side_amount keeps only the matching direction" do
    assert_equal 5, IncomeStatement::CategoryNetting.side_amount(5, :expense)
    assert_equal 0, IncomeStatement::CategoryNetting.side_amount(5, :income)
    assert_equal 5, IncomeStatement::CategoryNetting.side_amount(-5, :income)
    assert_equal 0, IncomeStatement::CategoryNetting.side_amount(-5, :expense)
  end

  private
    def transaction(amount, category)
      create_transaction(account: @account, amount: amount, category: category, date: @month)
    end

    def netting
      IncomeStatement::CategoryNetting.new(IncomeStatement.new(@family), period: Period.custom(start_date: @month, end_date: @month.end_of_month))
    end

    def group_for(category)
      netting.groups.find { |group| group[:category] == category }
    end

    def side_total(group, side)
      IncomeStatement::CategoryNetting.side_total(group, side)
    end
end
