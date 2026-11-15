require "test_helper"

class Category::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @target = create_category(@family, "Merge Target")
    @source = create_category(@family, "Merge Source")
  end

  test "moves transactions to the target and touches their entries" do
    entry = create_transaction(category: @source, account: accounts(:depository))
    entry.update_column(:updated_at, 1.day.ago)

    merge!(@source)

    assert_equal @target.id, entry.transaction.reload.category_id
    assert_in_delta Time.current, entry.reload.updated_at, 5.seconds
    assert_not Category.exists?(@source.id)
  end

  test "sums budget amounts when the target has a line in the same budget" do
    budget = create_budget(@family, 2.months.from_now.to_date.beginning_of_month)
    target_line = budget.budget_categories.create!(category: @target, budgeted_spending: 8, currency: budget.currency)
    source_line = budget.budget_categories.create!(category: @source, budgeted_spending: 12, currency: budget.currency)

    merge!(@source)

    assert_equal 20.to_d, target_line.reload.budgeted_spending
    assert_not BudgetCategory.exists?(source_line.id)
  end

  test "moves a budget line when the target has none in that budget" do
    budget = create_budget(@family, 3.months.from_now.to_date.beginning_of_month)
    source_line = budget.budget_categories.create!(category: @source, budgeted_spending: 12, currency: budget.currency)

    merge!(@source)

    assert_equal @target.id, source_line.reload.category_id
    assert_equal 12.to_d, source_line.budgeted_spending
  end

  test "moves subcategories under the target with the target colour" do
    @target.update!(color: "#123456")
    child = create_category(@family, "Merge Child", parent: @source)

    merge!(@source)

    child.reload
    assert_equal @target.id, child.parent_id
    assert_equal "#123456", child.color
  end

  test "moves recurring transactions" do
    recurring = recurring_transactions(:netflix_subscription)
    recurring.update_column(:category_id, @source.id)

    merge!(@source)

    assert_equal @target.id, recurring.reload.category_id
  end

  test "moves the category an import restores and the import category mapping" do
    import = imports(:transaction)
    entry = create_transaction(account: accounts(:depository))
    claim = import.claimed_entries.create!(entry: entry, previous_category_id: @source.id)
    mapping = Import::CategoryMapping.create!(import: import, key: "Old name", mappable: @source)

    merge!(@source)

    assert_equal @target.id, claim.reload.previous_category_id
    assert_equal @target, mapping.reload.mappable
  end

  test "moves rule action and condition values, also inside a condition group" do
    rule = @family.rules.create!(
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_category", operator: "=", value: @source.id),
        Rule::Condition.new(
          condition_type: "compound",
          operator: "or",
          sub_conditions: [
            Rule::Condition.new(condition_type: "transaction_category", operator: "=", value: @source.id),
            Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: @source.id)
          ]
        )
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @source.id) ]
    )

    merge!(@source)

    rule.reload
    assert_equal @target.id, rule.actions.first.value
    top_level = rule.conditions.find_by(condition_type: "transaction_category")
    assert_equal @target.id, top_level.value

    group = rule.conditions.find_by(condition_type: "compound")
    assert_equal @target.id, group.sub_conditions.find_by(condition_type: "transaction_category").value
    # A text condition that happens to hold the id is not a category reference
    assert_equal @source.id, group.sub_conditions.find_by(condition_type: "transaction_name").value
  end

  test "returns the merged category ids" do
    second = create_category(@family, "Second Source")

    merger = Category::Merger.new(family: @family, target_category: @target, source_categories: [ @source, second, @target ])

    assert_equal [ @source.id, second.id ].sort, merger.merge!.sort
    assert_equal 2, merger.merged_count
  end

  test "returns an empty list when the only source is the target" do
    merger = Category::Merger.new(family: @family, target_category: @target, source_categories: [ @target ])

    assert_equal [], merger.merge!
    assert Category.exists?(@target.id)
  end

  test "leaves another family's categories, transactions and rules alone" do
    other_target = create_category(@other_family, @target.name)
    other_source = create_category(@other_family, @source.name)
    other_rule = @other_family.rules.create!(
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: other_source.id) ]
    )

    assert_no_changes -> { [ Category.exists?(other_source.id), other_rule.actions.first.reload.value ] } do
      merge!(@source)
    end

    assert Category.exists?(other_target.id)
  end

  test "refuses a category of another family" do
    other_source = create_category(@other_family, "Other Source")

    assert_raises Category::Merger::UnauthorizedCategoryError do
      Category::Merger.new(family: @family, target_category: @target, source_categories: [ other_source ])
    end
  end

  test "refuses to merge across classifications" do
    income = create_category(@family, "Merge Income", classification: "income")

    error = assert_raises Category::Merger::ClassificationMismatchError do
      Category::Merger.new(family: @family, target_category: @target, source_categories: [ income ])
    end

    assert_includes error.message, "Merge Income"
    assert Category.exists?(income.id)
  end

  test "refuses to merge a parent into its own subcategory" do
    child = create_category(@family, "Merge Child", parent: @source)

    assert_raises Category::Merger::HierarchyError do
      Category::Merger.new(family: @family, target_category: child, source_categories: [ @source ])
    end
  end

  test "refuses to merge a category with subcategories into a subcategory" do
    create_category(@family, "Merge Child", parent: @source)
    sub_target = create_category(@family, "Merge Sub Target", parent: @target)

    assert_raises Category::Merger::HierarchyError do
      Category::Merger.new(family: @family, target_category: sub_target, source_categories: [ @source ])
    end
  end

  test "rolls everything back when a step fails" do
    entry = create_transaction(category: @source, account: accounts(:depository))
    second = create_category(@family, "Second Source")

    merger = Category::Merger.new(family: @family, target_category: @target, source_categories: [ @source, second ])
    merger.stubs(:move_rule_values).raises(ActiveRecord::StatementInvalid, "boom")

    assert_raises(ActiveRecord::StatementInvalid) { merger.merge! }

    assert_equal @source.id, entry.transaction.reload.category_id
    assert Category.exists?(@source.id)
    assert Category.exists?(second.id)
  end

  private
    def merge!(*sources)
      Category::Merger.new(family: @family, target_category: @target, source_categories: sources).merge!
    end

    def create_category(family, name, parent: nil, classification: "expense")
      family.categories.create!(name: name, color: "#000000", lucide_icon: "shapes", parent: parent, classification: classification)
    end

    def create_budget(family, start_date)
      family.budgets.create!(start_date: start_date, end_date: start_date.end_of_month, currency: family.currency || "USD")
    end
end
