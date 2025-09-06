class AddFiscalMonthToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :use_fiscal_months, :boolean, default: false, null: false
    add_column :families, :fiscal_month_start_day, :integer, default: 1, null: false

    # Optional: ensure valid range at DB level (Postgres CHECK)
    reversible do |dir|
      dir.up do
        execute <<~SQL
          ALTER TABLE families
          ADD CONSTRAINT fiscal_month_start_day_range
          CHECK (fiscal_month_start_day >= 1 AND fiscal_month_start_day <= 31);
        SQL
      end
      dir.down do
        execute <<~SQL
          ALTER TABLE families
          DROP CONSTRAINT IF EXISTS fiscal_month_start_day_range;
        SQL
      end
    end
  end
end

