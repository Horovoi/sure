# A CSV whose type column names outflows (e.g. "Списання") and has several inflow
# values (e.g. "Зарахування", "Повернення") cannot be described by one inflow value.
# Nullable and no backfill: existing imports keep using amount_type_inflow_value.
class AddAmountTypeOutflowValueToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :amount_type_outflow_value, :string
  end
end
