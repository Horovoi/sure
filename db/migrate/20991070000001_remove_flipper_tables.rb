# Flipper is gone: the only flag it held, db_sso_providers, is now read from
# AUTH_PROVIDERS_SOURCE by FeatureFlags. Its tables hold nothing else, so they
# are dropped. The rows are flag state only (no user data), but bin/deploy's
# row-loss guard reports a dropped table as lost rows, so the deploy that runs
# this needs the owner's confirmation and --allow-row-loss.
class RemoveFlipperTables < ActiveRecord::Migration[8.1]
  def up
    drop_table :flipper_gates, if_exists: true
    drop_table :flipper_features, if_exists: true
  end

  def down
    create_table :flipper_features do |t|
      t.string :key, null: false
      t.timestamps null: false
      t.index :key, unique: true
    end

    create_table :flipper_gates do |t|
      t.string :feature_key, null: false
      t.string :key, null: false
      t.text :value
      t.timestamps null: false
      t.index [ :feature_key, :key, :value ], unique: true
    end
  end
end
