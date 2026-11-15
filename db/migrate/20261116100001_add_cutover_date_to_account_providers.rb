# The day a provider takes over an account that already had manual history
# (Account::ProviderLink). Entries before it stay as the user entered them and
# balances before it are still calculated forward from the opening anchor; from
# it on the provider's transactions and balance are used. Null for accounts that
# were linked from the start.
class AddCutoverDateToAccountProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :account_providers, :cutover_date, :date
  end
end
