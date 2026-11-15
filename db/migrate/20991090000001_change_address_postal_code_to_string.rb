# Postal codes are labels, not numbers. As an integer column a Ukrainian code such as
# 01001 (Kyiv) was stored as 1001, and any code with letters was dropped. Existing
# values keep their digits; a leading zero lost before this change cannot be recovered.
class ChangeAddressPostalCodeToString < ActiveRecord::Migration[8.1]
  def up
    change_column :addresses, :postal_code, :string, using: "postal_code::text"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "postal codes may now hold letters or leading zeros, which an integer column cannot keep"
  end
end
