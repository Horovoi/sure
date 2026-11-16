require "test_helper"

class ReportsHelperTest < ActionView::TestCase
  FakeComparison = Struct.new(:rows, keyword_init: true) do
    def comparable? = true
    def normal_total = rows.sum { |row| row.normal.to_d }
  end

  setup do
    @family = families(:dylan_family)
    Current.session = users(:family_admin).sessions.create!
  end

  test "past the top rows only quiet categories fold away" do
    # Ten categories near normal and, eleventh, a small one far above it
    categories = 11.times.map { |index| @family.categories.create!(name: "Fold #{index}", classification: "expense", color: "#123456") }
    groups = categories.each_with_index.map { |category, index| group(category, 1_000 - (index * 10)) }
    rows = categories.each_with_index.map do |category, index|
      total = 1_000 - (index * 10)
      normal = index == 10 ? 100 : total
      IncomeStatement::SpendingComparison::Row.new(category: category, total: total.to_d, normal: normal.to_d, subcategories: [], direct: false)
    end

    column = breakdown_column(groups, total: groups.sum { |g| g[:total] }, type: :expense,
                              start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month,
                              comparison: FakeComparison.new(rows: rows))

    assert_equal %w[Fold\ 8 Fold\ 9], column[:tail].map { |row| row[:name] }
    loud = column[:rows].find { |row| row[:name] == "Fold 10" }
    assert_not loud[:folded], "a category far from normal stays in sight"
    assert_equal :unfavorable, loud[:delta][:tone]
    assert_equal "+800%", loud[:delta][:percent]
  end

  test "a change against a tiny normal shows no percent" do
    category = @family.categories.create!(name: "Tiny normal", classification: "expense", color: "#123456")
    row = IncomeStatement::SpendingComparison::Row.new(category: category, total: 500.to_d, normal: 1.to_d, subcategories: [], direct: false)

    column = breakdown_column([ group(category, 500) ], total: 500, type: :expense,
                              start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month,
                              comparison: FakeComparison.new(rows: [ row ]))

    assert_match(/\A\+/, column[:rows].first[:delta][:label])
    assert_nil column[:rows].first[:delta][:percent]
  end

  test "a change too small against the whole normal stays grey whatever its ratio" do
    big = @family.categories.create!(name: "Big normal", classification: "expense", color: "#123456")
    tiny = @family.categories.create!(name: "Tiny fees", classification: "expense", color: "#123456")
    rows = [
      IncomeStatement::SpendingComparison::Row.new(category: big, total: 10_000.to_d, normal: 10_000.to_d, subcategories: [], direct: false),
      # +50% of its normal, but 3 against a normal total of 10,006
      IncomeStatement::SpendingComparison::Row.new(category: tiny, total: 9.to_d, normal: 6.to_d, subcategories: [], direct: false)
    ]

    column = breakdown_column([ group(big, 10_000), group(tiny, 9) ], total: 10_009, type: :expense,
                              start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month,
                              comparison: FakeComparison.new(rows: rows))

    fees = column[:rows].find { |row| row[:name] == "Tiny fees" }
    assert_equal :neutral, fees[:delta][:tone]
    assert_equal "+50%", fees[:delta][:percent]
  end

  test "the first figure says what was left over or overspent" do
    left = breakdown_left_over(income_total: 400.to_d, expense_total: 300.to_d)
    assert_equal [ "Left over", "25% of income", :neutral ], left.values_at(:label, :note, :tone)
    over = breakdown_left_over(income_total: 300.to_d, expense_total: 400.to_d)
    assert_equal [ "Overspent", "More spent than came in", :unfavorable ], over.values_at(:label, :note, :tone)
    assert_nil breakdown_left_over(income_total: 0.to_d, expense_total: 400.to_d)
  end

  private
    def group(category, total)
      { category_id: category.id, category_name: category.name, category_color: category.color, category_icon: nil,
        type: "expense", total: total.to_d, count: 1, netted: 0, filter_value: category.name, has_transactions: true, subcategories: [] }
    end
end
