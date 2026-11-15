module CategoriesHelper
  def transfer_category
    Category.new \
      name: "Transfer",
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: "Payment",
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: "Trade",
      color: Category::TRADE_COLOR
  end

  # w2-transfers transfer-form-fixes: the outflow's category that the inflow leg of a
  # confirmed, categorizable transfer shows read-only (Uncategorized when it has none),
  # or nil for any other transaction.
  def transfer_outflow_category(transaction)
    return unless transaction.category_set_on_transfer_outflow?

    transaction.transfer_as_inflow.outflow_transaction.category || Category.uncategorized
  end

  # The badge a transaction shows when its category is not editable
  def read_only_category(transaction)
    transfer_outflow_category(transaction) || (transaction.payment? ? payment_category : transfer_category)
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically)
  end

  def grouped_family_categories
    Current.family.categories
           .roots
           .alphabetically
           .yield_self { |scope| Category::Group.for(scope) }
  end
end
