require "test_helper"

# The rule of split transactions (Entry::Splittable): every money figure of a family with
# splits equals the same figure computed with each split replaced by separate plain
# transactions (its parts), and the account balance equals the one its parent alone gives.
class Entry::SplitInvariantTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @food = categories(:food_and_drink)
    @other = categories(:subscriptions)
    @income = categories(:income)
    # After the fixture's valuation (4 days ago), so the entries move the balance
    @date = Date.current
    @period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)

    @expense_parts = [
      { name: "Groceries", amount: 60, category_id: @food.id },
      { name: "Household", amount: 30, category_id: @other.id, tag_ids: [ tags(:one).id ] },
      { name: "Paid back by a friend", amount: 15, category_id: @other.id, excluded: true },
      { name: "Bottle deposit", amount: -5, category_id: @food.id }
    ]
    @income_parts = [
      { name: "Salary", amount: -150, category_id: @income.id },
      { name: "Bonus", amount: -50 }
    ]
  end

  test "every aggregate counts the parts of a split, never its parent, and the balance its parent" do
    expense = create_transaction(account: @account, date: @date, amount: 100, name: "Supermarket", category: @food)
    income = create_transaction(account: @account, date: @date, amount: -200, name: "Employer", category: @income)
    expense.split!(@expense_parts)
    income.split!(@income_parts)

    with_split = snapshot

    [ expense, income ].each { |parent| parent.reload.unsplit! }
    expense.reload.destroy!
    income.reload.destroy!
    (@expense_parts + @income_parts).each { |part| create_plain(part) }

    with_plain = snapshot

    with_split.each_key do |figure|
      assert_equal with_plain[figure], with_split[figure], "#{figure} differs between the split and plain transactions"
    end
  end

  test "the balance follows the parent alone" do
    entry = create_transaction(account: @account, date: @date, amount: 100, name: "Supermarket")
    materialize
    before = @account.reload.balance

    entry.split!(@expense_parts)
    materialize
    assert_equal before, @account.reload.balance

    entry.reload.resplit!([ { amount: 99 }, { amount: 1 } ])
    materialize
    assert_equal before, @account.reload.balance

    entry.reload.unsplit!
    materialize
    assert_equal before, @account.reload.balance
  end

  test "the report caches see every split change" do
    entry = create_transaction(account: @account, date: @date, amount: 100)
    versions = [ Family.find(@family.id).entries_cache_version ]

    entry.split!([ { amount: 70 }, { amount: 30 } ])
    versions << Family.find(@family.id).entries_cache_version

    travel 1.second do
      child = entry.child_entries.first
      child.transaction.update!(category_id: @food.id)
      versions << Family.find(@family.id).entries_cache_version
    end

    travel 2.seconds do
      entry.reload.resplit!([ { amount: 50 }, { amount: 50 } ])
      versions << Family.find(@family.id).entries_cache_version
    end

    travel 3.seconds do
      entry.reload.unsplit!
      versions << Family.find(@family.id).entries_cache_version
    end

    assert_equal versions.size, versions.uniq.size
  end

  private
    def create_plain(part)
      entry = create_transaction(
        account: @account, date: @date, name: part[:name], amount: part[:amount],
        excluded: part[:excluded] || false,
        category: part[:category_id] && Category.find(part[:category_id])
      )
      entry.transaction.update!(tag_ids: part[:tag_ids]) if part[:tag_ids]
      entry
    end

    def materialize
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    def snapshot
      family = Family.find(@family.id)
      statement = IncomeStatement.new(family)
      materialize

      expense_totals = statement.expense_totals(period: @period)
      income_totals = statement.income_totals(period: @period)
      search_totals = Transaction::Search.new(family, filters: {}).totals
      food_search = Transaction::Search.new(family, filters: { "categories" => [ @food.name ] })
      budget = Budget.find_or_bootstrap(family, start_date: @period.start_date)
      comparison = IncomeStatement::SpendingComparison.new(statement, period: @period, history_start: IncomeStatement::SpendingComparison.history_start(family))
      mcp_transactions = Assistant::Function::GetTransactions.new(@user).call("start_date" => @period.start_date.iso8601, "end_date" => @period.end_date.iso8601, "page_size" => 100)
      mcp_statement = Assistant::Function::GetIncomeStatement.new(@user).call("start_date" => @period.start_date.iso8601, "end_date" => @period.end_date.iso8601)
      export_rows = CSV.parse(Family::DataExporter.new(family).send(:generate_transactions_csv), headers: true)

      {
        expense_total: expense_totals.total,
        income_total: income_totals.total,
        expense_by_category: by_category(expense_totals),
        income_by_category: by_category(income_totals),
        netting: IncomeStatement::CategoryNetting.new(statement, period: @period).groups.map { |group| group.to_h.except(:children).transform_values { |value| value.respond_to?(:id) ? value.id : value } },
        daily_expenses: statement.daily_expense_series(period: @period),
        daily_food_expenses: statement.daily_expense_series(period: @period, category_ids: [ @food.id ]),
        sankey: IncomeStatement::Sankey.new(statement, period: @period).as_json,
        comparison_total: comparison.total,
        comparison_rows: comparison.rows.map(&:to_h),
        search_totals: search_totals.to_h,
        search_count: Transaction::Search.new(family, filters: {}).transactions_scope.count,
        food_search_amounts: food_search.transactions_scope.map { |txn| txn.entry.amount }.sort,
        budget_spending: budget.actual_spending,
        budget_income: budget.actual_income,
        budget_categories: budget.budget_categories.map { |bc| [ bc.category_id, bc.actual_spending ] }.sort_by { |id, _| id.to_s },
        budget_transactions: budget.transactions.map { |txn| txn.entry.amount }.sort,
        mcp_totals: mcp_transactions.slice(:total_income, :total_expenses, :total_results),
        mcp_statement: mcp_statement.except(:generated_at),
        export_amounts: export_rows.map { |row| row["amount"].to_d }.sort,
        balance: @account.reload.balance
      }
    end

    def by_category(totals)
      totals.category_totals.reject { |ct| ct.total.zero? }.map { |ct| [ ct.category.id, ct.total ] }.sort_by { |id, _| id.to_s }
    end
end
