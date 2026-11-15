# Shared request slots for provider APIs that allow one request per interval
# (Provider::RateLimitable). One row per provider, credential scope and bucket;
# next_free_at is when the next request may go. Rows hold no secrets: scope_key
# is a digest of the credential.
class CreateProviderRateLimitSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_rate_limit_slots, id: :uuid do |t|
      t.string :provider_key, null: false
      t.string :scope_key, null: false
      t.string :bucket, null: false
      t.datetime :next_free_at, null: false

      t.timestamps
    end

    add_index :provider_rate_limit_slots, %i[provider_key scope_key bucket], unique: true,
      name: "index_provider_rate_limit_slots_on_key"
  end
end
