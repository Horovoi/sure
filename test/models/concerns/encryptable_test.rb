require "test_helper"

class EncryptableTest < ActiveSupport::TestCase
  class TestRecord
    include Encryptable
  end

  PROVIDER_CREDENTIALS = {
    PlaidItem => %w[access_token],
    LunchflowItem => %w[api_key],
    EnableBankingItem => %w[client_certificate session_id],
    CoinstatsItem => %w[api_key],
    CoinbaseItem => %w[api_key api_secret]
  }.freeze

  def keys(primary: "p" * 32, deterministic: "d" * 32, salt: "s" * 32)
    ActiveSupport::OrderedOptions.new.tap do |options|
      options.primary_key = primary
      options.deterministic_key = deterministic
      options.key_derivation_salt = salt
    end
  end

  test "keys in the app config are enough, as when they are derived from SECRET_KEY_BASE" do
    assert Encryptable.ready?(config: keys, credentials: nil)
  end

  test "keys in the credentials are enough" do
    credentials = { primary_key: "p", deterministic_key: "d", key_derivation_salt: "s" }

    assert Encryptable.ready?(config: ActiveSupport::OrderedOptions.new, credentials: credentials)
  end

  test "a blank or missing key is not ready" do
    assert_not Encryptable.ready?(config: keys(primary: ""), credentials: nil)
    assert_not Encryptable.ready?(config: keys(deterministic: nil), credentials: nil)
    assert_not Encryptable.ready?(config: keys(salt: " "), credentials: {})
    assert_not Encryptable.ready?(config: ActiveSupport::OrderedOptions.new, credentials: { primary_key: "p" })
    assert_not Encryptable.ready?(config: nil, credentials: nil)
  end

  test "the class method reads the app config" do
    Encryptable.stubs(:ready?).returns(false)
    assert_not TestRecord.encryption_ready?

    Encryptable.stubs(:ready?).returns(true)
    assert TestRecord.encryption_ready?
  end

  test "the test environment config counts as ready" do
    assert Encryptable.ready?
    PROVIDER_CREDENTIALS.each_key { |model| assert model.encryption_ready?, "#{model} should be ready" }
  end

  test "each provider item declares its credential columns encrypted" do
    PROVIDER_CREDENTIALS.each do |model, columns|
      encrypted = model.encrypted_attributes.map(&:to_s)

      columns.each do |column|
        assert_includes encrypted, column, "#{model}.#{column} should be encrypted"
      end
    end
  end

  test "a saved provider credential is ciphertext in the database" do
    item = CoinbaseItem.create!(family: families(:dylan_family), name: "Coinbase", api_key: "plain_key", api_secret: "plain_secret")

    raw_key, raw_secret = CoinbaseItem.connection.select_rows(
      CoinbaseItem.sanitize_sql([ "SELECT api_key, api_secret FROM coinbase_items WHERE id = ?", item.id ])
    ).first

    assert_not_equal "plain_key", raw_key
    assert_not_equal "plain_secret", raw_secret
    assert ActiveRecord::Encryption.encryptor.encrypted?(raw_key)
    assert ActiveRecord::Encryption.encryptor.encrypted?(raw_secret)
    assert_equal "plain_key", item.reload.api_key
    assert_equal item, CoinbaseItem.find_by(api_key: "plain_key")
  end
end
