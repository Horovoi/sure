# Mixing currencies in Money arithmetic (+, -, /, <=>) raises in development and test, so
# code that forgets a conversion fails loudly there. Production reports each call site once
# (Rails.error, the log and the debug log) and keeps the old result (see
# Money#ensure_same_currency!).
Rails.application.config.to_prepare do
  Money.strict_currency = Rails.env.local?
end
