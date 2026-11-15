# monobank (personal API) settings.
#
# monobank allows one request per 60 seconds per token per function (client-info,
# statement), a statement window of at most 31 days + 1 hour and 500 rows per
# response. The statement is therefore fetched by a chain of background jobs, one
# request per run (MonobankStatementFetchJob); a sync never waits for the bank.
#
# Environment:
#   MONOBANK_API_BASE_URL          API host. Only https://api.monobank.ua or a loopback
#                                  host (tests, the local fake) is accepted.
#   MONOBANK_MIN_REQUEST_INTERVAL  Seconds between two requests of one function (60).
#   MONOBANK_INITIAL_HISTORY_DAYS  History a new product reaches back to (365, 1..1095).
#   MONOBANK_INCLUDE_PENDING       Import holds as pending entries (on). A connection
#                                  can turn it off for itself.
#   MONOBANK_PENDING_LOOKBACK_DAYS Days a forward fetch re-reads (3, 1..31).
Rails.application.configure do
  config.x.monobank.include_pending =
    !ENV["MONOBANK_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[0 false no off])

  config.x.monobank.initial_history_days =
    ENV.fetch("MONOBANK_INITIAL_HISTORY_DAYS", 365).to_i.clamp(1, 1095)

  config.x.monobank.pending_lookback_days =
    ENV.fetch("MONOBANK_PENDING_LOOKBACK_DAYS", 3).to_i.clamp(1, 31)
end

Rails.application.config.to_prepare do
  if defined?(BankConnections) && BankConnections.respond_to?(:register)
    BankConnections.register(
      :monobank,
      association: :monobank_items,
      item_class_name: "MonobankItem",
      account_class_name: "MonobankAccount",
      label: "monobank",
      description: I18n.t("monobank_items.registration.description", default: "Ukrainian monobank cards, currency accounts, FOP accounts and jars, with a personal API token."),
      docs_url: "https://api.monobank.ua/",
      hourly: true,
      balance_includes_pending: true,
      settings_partial: "settings/providers/monobank_panel",
      generic_listing: true
    )
  end
end
