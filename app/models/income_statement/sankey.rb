# Cash-flow Sankey by category: income categories -> Cash Flow -> expense
# categories, netted by IncomeStatement::CategoryNetting. A month that spends more
# than it earns gets a Deficit source into Cash Flow, so the chart still balances.
#
# Node ids are stable across requests (the chart's zoom and subcategory filter
# read them): "<side>_<totals key>" for a category, "<side>_sub_<id>" for a
# subcategory, "<side>_sub_<totals key>_other" for the Other [Category] leaf.
class IncomeStatement::Sankey
  # The default colour of the Investment Contributions category.
  INVESTED_COLOR = "#0d9488".freeze

  KIND_COLORS = {
    cash_flow: "var(--color-success)",
    surplus: "var(--color-success)",
    deficit: "var(--color-destructive)"
  }.freeze

  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  def as_json(*)
    @nodes, @links = [], []
    groups = IncomeStatement::CategoryNetting.new(@statement, period: @period).groups
    income = groups.sum { |group| side_total(group, :income) }.to_d
    spending = groups.sum { |group| side_total(group, :expense) }.to_d
    # Zero while investment contributions count as spending (decision 29).
    invested = @statement.invested_total(period: @period).amount.to_d
    capacity = [ income, spending + invested ].max
    unless capacity.zero?
      center = add_node("cash_flow_node", node_name(:cash_flow), :cash_flow, capacity, 100)
      groups.each do |group|
        add_group(group, :income, income, center)
        add_group(group, :expense, spending, center)
      end
      unless invested.zero?
        index = add_node("invested_node", node_name(:invested), :invested, invested, percentage(invested, capacity), color: INVESTED_COLOR)
        add_link(center, index, invested, percentage(invested, capacity))
      end
      net = income - spending - invested
      unless net.zero?
        kind = net.positive? ? :surplus : :deficit
        index = add_node("#{kind}_node", node_name(kind), kind, net.abs, percentage(net.abs, capacity))
        source, target = net.positive? ? [ center, index ] : [ index, center ]
        add_link(source, target, net.abs, percentage(net.abs, capacity))
      end
    end
    { basis: "net_by_category", income: decimal(income), spending: decimal(spending), invested: decimal(invested),
      net_savings: decimal(income - spending), currency_symbol: currency_symbol, nodes: @nodes, links: @links }
  end

  private
    def category_key(category) = IncomeStatement::CategoryNetting.key(category)
    def side_amount(net, side) = IncomeStatement::CategoryNetting.side_amount(net, side)
    def side_total(group, side) = IncomeStatement::CategoryNetting.side_total(group, side)

    def add_group(group, side, total, center)
      amount = side_total(group, side)
      return if amount.zero?
      category = group[:category]
      pct = percentage(amount, total)
      root = add_node("#{side}_#{category_key(category)}", category.name, side, amount, pct, category)
      source, target = side == :income ? [ root, center ] : [ center, root ]
      add_link(source, target, amount, pct)

      linked_children = 0
      group[:children].each do |child|
        value = side_amount(child[:net], side)
        next if value.zero?
        linked_children += 1
        child_category = child[:category]
        child_pct = percentage(value, amount)
        index = add_node("#{side}_sub_#{child_category.id}", child_category.name, side, value, child_pct, child_category)
        source, target = side == :income ? [ index, root ] : [ root, index ]
        add_link(source, target, value, child_pct)
      end

      add_other_leaf(group, side, amount, root) if linked_children.positive?
    end

    # The parent's own transactions, beside its subcategories, so the parent's
    # links add up to its value. It has no filter value: filtering by the parent
    # name would also list the subcategories' transactions.
    def add_other_leaf(group, side, amount, root)
      value = side_amount(group[:direct], side)
      return if value.zero?
      category = group[:category]
      pct = percentage(value, amount)
      index = add_node("#{side}_sub_#{category_key(category)}_other",
        I18n.t("pages.dashboard.cashflow_sankey.other_category", category: category.name),
        side, value, pct, color: category.color)
      source, target = side == :income ? [ index, root ] : [ root, index ]
      add_link(source, target, value, pct)
    end

    def add_node(id, name, kind, value, percentage, category = nil, color: category&.color || KIND_COLORS[kind.to_sym])
      @nodes << { id: id, name: name, kind: kind.to_s, value: decimal(value), percentage: decimal(percentage),
        category_id: category&.id, filter_value: category && !category.other_investments? ? category.filter_value : nil,
        color: color }
      @nodes.size - 1
    end

    def add_link(source, target, value, percentage)
      @links << { source: source, target: target, value: decimal(value), percentage: decimal(percentage) }
    end

    def node_name(kind)
      I18n.t("pages.dashboard.cashflow_sankey.nodes.#{kind}")
    end

    def currency_symbol
      Money::Currency.new(@statement.family.currency).symbol
    end

    def percentage(value, total)
      total.zero? ? 0 : (value.to_d / total * 100).round(1)
    end

    def decimal(value)
      value.to_d.to_s("F")
    end
end
