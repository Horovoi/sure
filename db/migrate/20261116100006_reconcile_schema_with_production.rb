# db/schema.rb and production had drifted apart since an upstream schema merge in January 2026:
# - schema.rb listed accounts.holdings_snapshot_* and six trades realized-gain/cost-basis columns
#   (plus an index) that no migration ever created and no code reads; only test databases had them.
# - Production names the merchant uniqueness index idx_recurring_txns_on_family_merchant_amount_currency
#   and lacks the name uniqueness index (family_id, name, amount, currency) for name-only rows.
# Each step checks what is there, so it runs on production and on a database loaded from schema.rb alike.
class ReconcileSchemaWithProduction < ActiveRecord::Migration[8.1]
  UNUSED_COLUMNS = {
    accounts: { holdings_snapshot_data: :jsonb, holdings_snapshot_at: :datetime },
    trades: {
      realized_gain: [ :decimal, { precision: 19, scale: 4 } ],
      cost_basis_amount: [ :decimal, { precision: 19, scale: 4 } ],
      cost_basis_currency: :string,
      holding_period_days: :integer,
      realized_gain_confidence: :string,
      realized_gain_currency: :string
    }
  }.freeze

  OLD_MERCHANT_INDEX = "idx_recurring_txns_on_family_merchant_amount_currency".freeze
  MERCHANT_INDEX = "idx_recurring_txns_merchant".freeze
  NAME_INDEX = "idx_recurring_txns_name".freeze

  def up
    if index_name_exists?(:recurring_transactions, OLD_MERCHANT_INDEX)
      remove_index :recurring_transactions, name: OLD_MERCHANT_INDEX
    end
    unless index_name_exists?(:recurring_transactions, MERCHANT_INDEX)
      add_index :recurring_transactions, %i[family_id merchant_id amount currency],
        unique: true, name: MERCHANT_INDEX, where: "merchant_id IS NOT NULL"
    end

    unless index_name_exists?(:recurring_transactions, NAME_INDEX)
      duplicates = select_all(<<~SQL.squish).to_a
        SELECT family_id, name, amount, currency, COUNT(*) AS copies
        FROM recurring_transactions
        WHERE name IS NOT NULL AND merchant_id IS NULL
        GROUP BY family_id, name, amount, currency
        HAVING COUNT(*) > 1
      SQL
      if duplicates.any?
        raise "Duplicate name-only recurring transactions block #{NAME_INDEX}; merge these first: #{duplicates.inspect}"
      end

      add_index :recurring_transactions, %i[family_id name amount currency],
        unique: true, name: NAME_INDEX, where: "name IS NOT NULL AND merchant_id IS NULL"
    end

    remove_index :trades, name: "index_trades_on_realized_gain_not_null", if_exists: true
    UNUSED_COLUMNS.each do |table, columns|
      columns.each_key { |column| remove_column table, column, if_exists: true }
    end
  end

  def down
    UNUSED_COLUMNS.each do |table, columns|
      columns.each do |column, type|
        type, options = Array(type)
        add_column table, column, type, **(options || {}), if_not_exists: true
      end
    end
    add_index :trades, :realized_gain, name: "index_trades_on_realized_gain_not_null",
      where: "realized_gain IS NOT NULL", if_not_exists: true
    remove_index :recurring_transactions, name: NAME_INDEX, if_exists: true
  end
end
