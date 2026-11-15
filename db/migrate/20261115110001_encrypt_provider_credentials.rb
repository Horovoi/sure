# Provider items used to skip their `encrypts` declarations whenever the keys
# were derived from SECRET_KEY_BASE (the self-hosted default), so their
# credential columns hold plain text. Now that the models encrypt them, a
# plain-text value can no longer be read. This rewrites every plain-text value
# as ciphertext with the same scheme the model declares.
#
# The data is read with SQL so a plain-text value never goes through the
# encrypted attribute type. NULL and existing ciphertext are skipped, so a
# second run changes nothing. Down does nothing: decrypting would write the
# credentials back in plain text.
class EncryptProviderCredentials < ActiveRecord::Migration[8.1]
  # Table => { column => deterministic? }, matching the provider item models.
  COLUMNS = {
    "plaid_items" => { "access_token" => true },
    "lunchflow_items" => { "api_key" => true },
    "enable_banking_items" => { "client_certificate" => true, "session_id" => true },
    "coinstats_items" => { "api_key" => true },
    "coinbase_items" => { "api_key" => true, "api_secret" => false }
  }.freeze

  KEY_NAMES = %i[primary_key deterministic_key key_derivation_salt].freeze

  def up
    unless encryption_configured?
      say "Active Record encryption has no keys; provider credentials left as they are"
      return
    end

    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      model = record_class(table, columns)
      columns.each_key do |column|
        next unless column_exists?(table, column)

        say_with_time "Encrypting #{table}.#{column}" do
          encrypt_column(model, table, column)
        end
      end
    end
  end

  def down
    # Nothing to undo: the models read ciphertext, and plain text is what this fixed.
  end

  private
    def encrypt_column(model, table, column)
      rows = select_rows(<<~SQL.squish)
        SELECT id, #{quote_column_name(column)} FROM #{quote_table_name(table)}
        WHERE #{quote_column_name(column)} IS NOT NULL
      SQL

      rows.count do |id, raw|
        next false if raw.blank? || ciphertext?(raw)

        model.find(id).update_columns(column => raw)
        true
      end
    end

    def ciphertext?(value)
      ActiveRecord::Encryption.encryptor.encrypted?(value)
    end

    # A throwaway model per table, so the migration keeps working when the app
    # models change. It declares the same encryption as the app model.
    def record_class(table, columns)
      Class.new(ActiveRecord::Base) do
        self.table_name = table
        self.inheritance_column = nil
        define_singleton_method(:name) { "EncryptProviderCredentials::#{table.classify}" }

        columns.each do |column, deterministic|
          encrypts column.to_sym, deterministic: deterministic
        end
      end
    end

    def encryption_configured?
      [ Rails.application.config.active_record.encryption,
        Rails.application.credentials.active_record_encryption ].any? do |source|
        source.present? && KEY_NAMES.all? { |name| source[name].present? }
      end
    end
end
