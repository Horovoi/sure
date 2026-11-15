# Replaces live provider credentials in the staging copy with placeholders, so that
# nothing run against the copy can act on a real bank, exchange or sign-in provider.
# Run by `bin/staging refresh` inside the staging stack only.
abort "defuse.rb only runs in staging" unless ENV["STAGING_CLONE"] == "1"

CREDENTIALS = {
  "PlaidItem" => %w[access_token],
  "LunchflowItem" => %w[api_key],
  "CoinbaseItem" => %w[api_key api_secret],
  "CoinstatsItem" => %w[api_key],
  "EnableBankingItem" => %w[session_id client_certificate],
  "MonobankItem" => %w[access_token],
  "SsoProvider" => %w[client_secret]
}.freeze

replaced = 0
CREDENTIALS.each do |model_name, attributes|
  model = model_name.safe_constantize or next
  columns = attributes & model.column_names

  model.unscoped.find_each do |record|
    present = columns.select { |column| record.read_attribute_before_type_cast(column).present? }
    next if present.empty?

    present.each do |column|
      # Written the way the model stores it: encrypted if encryption is on, plain text if not
      stored = model.type_for_attribute(column).serialize("staging-copy-#{column}-#{record.id}")
      model.unscoped.where(model.primary_key => record.id).update_all([ "#{model.connection.quote_column_name(column)} = ?", stored ])
    end
    replaced += present.size
  end
end

puts "provider credentials replaced with placeholders: #{replaced}"
