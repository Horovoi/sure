# Cache keys of converted figures carry the newest stored rate into the family currency
# (ExchangeRate.conversion_cache_key, Family#build_cache_key), so a rate that arrives
# later replaces a cached total. That read runs on every dashboard, report and
# transactions render; without an index it scans the whole exchange_rates table.
#
# (to_currency, updated_at) replaces the single-column to_currency index: with
# to_currency leading it serves the same lookups. Both indexes are built concurrently.
class IndexExchangeRatesByUpdatedAt < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  UPDATED_AT_INDEX = "index_exchange_rates_on_updated_at"
  CURRENCY_UPDATED_AT_INDEX = "index_exchange_rates_on_to_currency_and_updated_at"
  CURRENCY_INDEX = "index_exchange_rates_on_to_currency"

  def up
    add_valid_index UPDATED_AT_INDEX, [ :updated_at ]
    add_valid_index CURRENCY_UPDATED_AT_INDEX, [ :to_currency, :updated_at ]

    # Drop the old index only once its replacement exists and is valid, so to_currency
    # lookups never lose their index
    unless valid_index?(CURRENCY_UPDATED_AT_INDEX)
      raise "#{CURRENCY_UPDATED_AT_INDEX} is missing or invalid; keeping #{CURRENCY_INDEX}"
    end

    remove_index :exchange_rates, name: CURRENCY_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    add_valid_index CURRENCY_INDEX, [ :to_currency ]
    remove_index :exchange_rates, name: CURRENCY_UPDATED_AT_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :exchange_rates, name: UPDATED_AT_INDEX, algorithm: :concurrently, if_exists: true
  end

  private
    # An interrupted CREATE INDEX CONCURRENTLY leaves an INVALID index whose name is still in
    # the catalog, so if_not_exists would accept it. Only a valid index counts; an invalid
    # leftover is dropped and built again.
    def add_valid_index(name, columns)
      return if valid_index?(name)

      execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(name)}"
      add_index :exchange_rates, columns, name: name, algorithm: :concurrently
    end

    def valid_index?(name)
      select_value(<<~SQL.squish) == true
        SELECT pg_index.indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = #{quote(name)}
      SQL
    end
end
