# monobank (personal API) connections and their products: cards, currency
# accounts, FOP accounts and jars. The statement is fetched by a chain of
# background jobs, one request per run, so the fetch state lives on
# monobank_accounts (see MonobankItem::FetchPlan).
class CreateMonobankItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :monobank_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false
      t.date :sync_start_date
      t.text :access_token
      t.string :client_id
      t.jsonb :raw_payload
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color
      t.boolean :include_pending, null: false, default: true
      t.boolean :apply_mcc_categories, null: false, default: true
      t.uuid :fetch_chain_token
      t.datetime :fetch_chain_heartbeat_at
      t.datetime :force_forward_until
      t.datetime :last_client_info_at
      t.timestamps
    end

    add_index :monobank_items, :status

    create_table :monobank_accounts, id: :uuid do |t|
      t.references :monobank_item, null: false, foreign_key: true, type: :uuid
      t.string :account_id, null: false
      t.string :name, null: false
      t.string :currency, null: false
      t.string :account_kind, null: false
      t.string :account_type
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :credit_limit, precision: 19, scale: 4
      t.bigint :raw_balance_minor
      t.decimal :goal, precision: 19, scale: 4
      t.string :last4
      t.boolean :ignored, null: false, default: false
      t.date :sync_start_date
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload, null: false, default: []
      t.datetime :history_synced_from
      t.datetime :statement_synced_through
      t.datetime :page_from
      t.datetime :page_to
      t.string :page_kind
      t.jsonb :page_seen_ids, null: false, default: []
      t.bigint :balance_at_forward_fetch
      t.datetime :forward_fetched_at
      t.boolean :history_complete, null: false, default: false
      t.integer :fetch_failures, null: false, default: 0
      t.datetime :next_fetch_after
      t.datetime :opening_anchor_set_at
      t.timestamps
    end

    add_index :monobank_accounts, [ :monobank_item_id, :account_id ], unique: true
  end
end
