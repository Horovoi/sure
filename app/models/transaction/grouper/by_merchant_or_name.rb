# One group per merchant, and one per name for transactions without a merchant, split
# into income and expense. The database counts the groups, so only the entries of the
# returned groups are loaded.
class Transaction::Grouper::ByMerchantOrName < Transaction::Grouper
  TYPE_SQL = "CASE WHEN #{INCOME_SQL} THEN 'income' ELSE 'expense' END".freeze

  def self.call(entries, limit: 20, offset: 0)
    new(entries).call(limit: limit, offset: offset)
  end

  def initialize(entries)
    @entries = entries
  end

  def call(limit: 20, offset: 0)
    rows = group_rows(limit: limit, offset: offset)
    merchants = Merchant.where(id: rows.filter_map { |row| row[:merchant_id] }).index_by(&:id)

    rows.filter_map do |row|
      merchant = merchants[row[:merchant_id]]
      group_entries = entries_for(row).to_a
      next if group_entries.empty?

      name = merchant&.name || row[:name]

      Transaction::Grouper::Group.new(
        grouping_key: name,
        display_name: name,
        entries: group_entries,
        merchant: merchant,
        transaction_type: row[:transaction_type]
      )
    end
  end

  private
    attr_reader :entries

    def uncategorized
      entries.uncategorized_transactions
    end

    # [{ merchant_id:, name:, transaction_type: }], largest group first, then by name
    def group_rows(limit:, offset:)
      name_key = "CASE WHEN transactions.merchant_id IS NULL THEN entries.name END"
      sort_name = "LOWER(COALESCE(MAX(merchants.name), MAX(entries.name)))"

      uncategorized
        .joins("LEFT JOIN merchants ON merchants.id = transactions.merchant_id")
        .group(Arel.sql("transactions.merchant_id"), Arel.sql(name_key), Arel.sql(TYPE_SQL))
        .order(Arel.sql("COUNT(*) DESC"), Arel.sql("#{sort_name} ASC"), Arel.sql("#{TYPE_SQL} ASC"))
        .offset([ offset.to_i, 0 ].max)
        .limit(limit)
        .pluck(Arel.sql("transactions.merchant_id"), Arel.sql(name_key), Arel.sql(TYPE_SQL))
        .map { |merchant_id, name, type| { merchant_id: merchant_id, name: name, transaction_type: type } }
    end

    def entries_for(row)
      scope = uncategorized
      scope = if row[:merchant_id]
        scope.where(transactions: { merchant_id: row[:merchant_id] })
      else
        scope.where(transactions: { merchant_id: nil }, name: row[:name])
      end
      scope = row[:transaction_type] == "income" ? scope.where(INCOME_SQL) : scope.where.not(INCOME_SQL)

      scope.includes(:account, entryable: :merchant).order(date: :desc, id: :desc)
    end
end
