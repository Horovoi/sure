# Marks gap-filled (LOCF) exchange rates as provisional, like security_prices.provisional,
# so the importer refetches them once the provider publishes that day.
class AddProvisionalToExchangeRates < ActiveRecord::Migration[7.2]
  def up
    add_column :exchange_rates, :provisional, :boolean, null: false, default: false

    # One-time data fix: existing gap-fills cannot be told apart from real rates, so the
    # recent ones (the importer's 7-day lookback) are marked provisional and refetched
    # once. Real rates come back as final; gap-fills are replaced or kept provisional.
    execute <<~SQL
      UPDATE exchange_rates SET provisional = true WHERE date >= CURRENT_DATE - 7
    SQL
  end

  def down
    remove_column :exchange_rates, :provisional
  end
end
