# "Sync now" is recorded as the time it was asked for (it no longer expires), and a
# paged statement window keeps the client-info balance seen when its first page was
# requested.
class MonobankFetchRequestAndPageBalance < ActiveRecord::Migration[8.1]
  def change
    rename_column :monobank_items, :force_forward_until, :force_forward_requested_at
    add_column :monobank_accounts, :page_balance_minor, :bigint
  end
end
