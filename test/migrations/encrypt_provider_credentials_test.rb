require "test_helper"
# The stamp changes when the migration is re-stamped, so find it by name.
require Dir[Rails.root.join("db/migrate/*_encrypt_provider_credentials.rb")].first

class EncryptProviderCredentialsTest < ActiveSupport::TestCase
  setup do
    family = families(:dylan_family)

    @plaintext = {
      [ "plaid_items", plaid_items(:one).id, "access_token" ] => "plain_access_token",
      [ "lunchflow_items", lunchflow_items(:one).id, "api_key" ] => "plain_lunchflow_key"
    }

    coinbase = CoinbaseItem.create!(family: family, name: "Coinbase", api_key: "x", api_secret: "x")
    coinstats = CoinstatsItem.create!(family: family, name: "CoinStats", api_key: "x")
    enable_banking = EnableBankingItem.create!(
      family: family, name: "Enable Banking", country_code: "FI", application_id: "app", client_certificate: "x"
    )

    @plaintext[[ "coinbase_items", coinbase.id, "api_key" ]] = "plain_coinbase_key"
    @plaintext[[ "coinbase_items", coinbase.id, "api_secret" ]] = "plain_coinbase_secret"
    @plaintext[[ "coinstats_items", coinstats.id, "api_key" ]] = "plain_coinstats_key"
    @plaintext[[ "enable_banking_items", enable_banking.id, "client_certificate" ]] = "-----BEGIN PRIVATE KEY-----\nplain"
    @plaintext[[ "enable_banking_items", enable_banking.id, "session_id" ]] = "plain_session"

    # Write the values the way the old code stored them: plain text, past the encrypted type.
    @plaintext.each { |(table, id, column), value| write_raw(table, id, column, value) }

    @models = {
      "plaid_items" => PlaidItem, "lunchflow_items" => LunchflowItem, "coinbase_items" => CoinbaseItem,
      "coinstats_items" => CoinstatsItem, "enable_banking_items" => EnableBankingItem
    }
  end

  test "rewrites plain-text credentials as ciphertext the models can read" do
    migrate

    @plaintext.each do |(table, id, column), value|
      raw = read_raw(table, id, column)

      assert_not_equal value, raw, "#{table}.#{column} is still plain text"
      assert ActiveRecord::Encryption.encryptor.encrypted?(raw), "#{table}.#{column} is not ciphertext"
      assert_equal value, @models.fetch(table).find(id).public_send(column)
    end
  end

  test "a second run changes nothing" do
    migrate
    after_first = @plaintext.keys.index_with { |key| read_raw(*key) }

    migrate

    after_first.each do |key, raw|
      assert_equal raw, read_raw(*key), "#{key.first}.#{key.last} changed on the second run"
    end
  end

  test "deterministic columns still find the record" do
    migrate

    assert_equal plaid_items(:one), PlaidItem.find_by(access_token: "plain_access_token")
  end

  test "NULL stays NULL" do
    id = @plaintext.keys.find { |table, _, column| table == "enable_banking_items" && column == "session_id" }[1]
    write_raw("enable_banking_items", id, "session_id", nil)

    migrate

    assert_nil read_raw("enable_banking_items", id, "session_id")
  end

  private
    def migrate
      ActiveRecord::Migration.suppress_messages { EncryptProviderCredentials.new.up }
    end

    def write_raw(table, id, column, value)
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([ "UPDATE #{table} SET #{column} = ? WHERE id = ?", value, id ])
      )
    end

    def read_raw(table, id, column)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql([ "SELECT #{column} FROM #{table} WHERE id = ?", id ])
      )
    end
end
