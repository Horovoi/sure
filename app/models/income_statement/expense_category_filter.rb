# The category filter of the dashboard's spending curve: which categories it offers,
# which of them are checked, and what the selection resolves to.
#
# Values are Category#filter_value (a category's name, the sentinel for Uncategorized),
# the same values the transactions category filter takes, so a selection reads the same
# in both places.
#
# Options are listed by category group (a top-level category and its subcategories):
# every group with spending in the given periods, plus any group with a picked
# category. A group is listed whole, so the parent/subcategory cascade sees every child,
# and picking a parent covers them all. Uncategorized comes first. An option is checked
# when it was picked, or its parent was, or nothing was picked at all; it is live when
# its group has spending.
#
# The selection resolves to nil (unfiltered) when every option is checked and live: that
# draws exactly what the unfiltered curve draws. A picked category with no spending keeps
# the filter, so it survives a period where it is empty.
class IncomeStatement::ExpenseCategoryFilter
  Option = Data.define(:category, :value, :checked, :live)

  attr_reader :options, :values

  # The submitted values that name one of the family's categories (or Uncategorized),
  # or nil when none does. A real category named like the legacy uncategorized value
  # keeps its own meaning.
  def self.sanitize(family, raw_values)
    names = family.categories.pluck(:name)
    values = Array(raw_values).map(&:to_s).reject(&:blank?).filter_map do |value|
      if names.include?(value)
        value
      elsif Category.uncategorized_filter_value?(value)
        Category::UNCATEGORIZED_FILTER_VALUE
      end
    end

    values.uniq.presence
  end

  # values: sanitized filter values (see .sanitize); nil means nothing was picked
  def initialize(income_statement, periods:, values:)
    @income_statement = income_statement
    @categories = income_statement.family.categories.alphabetically_by_hierarchy.includes(:parent).to_a
    @options = build_options(periods, values)
    @values = values unless @options.all? { |option| option.checked && option.live }
  end

  # The selection as IncomeStatement#daily_expense_series takes it: category ids, the
  # uncategorized sentinel; nil when unfiltered
  def category_ids
    return nil if values.nil?

    ids_by_name = @categories.to_h { |category| [ category.name, category.id ] }
    values.filter_map do |value|
      value == Category::UNCATEGORIZED_FILTER_VALUE ? value : ids_by_name[value]
    end
  end

  # How many categories the selection covers, counted where spending is filed: a
  # category with subcategories counts as its subcategories, not itself as well
  def selected_count
    parent_ids = options.filter_map { |option| option.category.parent_id }
    options.count { |option| option.checked && !parent_ids.include?(option.category.id) }
  end

  private
    def build_options(periods, values)
      used_ids = periods.flat_map { |period| @income_statement.daily_expense_category_ids(period: period) }.uniq
      picked = Array(values)

      group_of = ->(category) { category.parent_id || category.id }
      live_groups = @categories.select { |category| used_ids.include?(category.id) }.map(&group_of)
      shown_groups = live_groups + @categories.select { |category| picked.include?(category.name) }.map(&group_of)
      categories = @categories.select { |category| shown_groups.include?(group_of.call(category)) }
      categories.unshift(Category.uncategorized) if used_ids.include?(nil) || picked.include?(Category::UNCATEGORIZED_FILTER_VALUE)

      categories.map do |category|
        Option.new(
          category: category,
          value: category.filter_value,
          checked: values.nil? || picked.include?(category.filter_value) || (category.parent.present? && picked.include?(category.parent.filter_value)),
          live: category.persisted? ? live_groups.include?(group_of.call(category)) : used_ids.include?(nil)
        )
      end
    end
end
