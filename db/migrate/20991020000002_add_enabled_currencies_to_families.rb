# The currencies a family offers in money fields. NULL (the default, and what
# every existing family gets) means every currency, as before; a list narrows
# the pickers to it. The base currency and a record's own currency are always
# offered on top (Family#enabled_currency_codes).
class AddEnabledCurrenciesToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :enabled_currencies, :string, array: true
  end
end
