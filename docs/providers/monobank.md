# monobank

Sure reads monobank's personal API (https://api.monobank.ua/docs/) with a personal
token. It imports every product the token sees: each card and currency account
(UAH, USD, EUR), FOP accounts and jars. It only reads; it cannot move money.

## Turn it on

1. Set `BANK_CONNECTIONS_ENABLED=monobank` (other providers stay off) and deploy.
2. Open https://api.monobank.ua/, sign in with the QR code in the monobank app and
   copy the token.
3. Settings › Sync Providers › monobank: paste the token, connect.
4. Set up accounts: for each product choose a new Sure account, or link an account
   you already keep (for example a card you entered by hand). For a linked account,
   transactions from the cut-over date (default: the day after its last entry) come
   from monobank; earlier history stays as entered. Rows within 3 days of an entry
   with the same amount take that entry over instead of adding a second one.

After linking, CSV and PDF statement imports into that account are refused.

## How it fetches

monobank answers one request per minute per token and function, at most 31 days
per statement request and 500 rows per answer. A sync never waits for that: it
refreshes the account list when it can, books the rows already fetched, and starts
a background chain (`MonobankStatementFetchJob`) that makes one request per run and
reschedules itself for the next free minute. The chain asks for a sync every 5
windows, so entries appear while a year of history loads (about 12 requests per
product). Afterwards the hourly sync fetches only products whose balance changed,
or that have open holds.

Holds are imported as pending entries and replaced when they settle. MCC codes give
a category to uncategorised transactions (Settings › Sync Providers › monobank,
"Categorise by MCC"); own transfers between your products are never categorised
and are suggested as transfers instead.

There are no webhooks: production is reachable only on the local network.

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `MONOBANK_MIN_REQUEST_INTERVAL` | 60 | Seconds between two requests of one function |
| `MONOBANK_INITIAL_HISTORY_DAYS` | 365 | History of a new product (1..1095) |
| `MONOBANK_INCLUDE_PENDING` | on | Import holds as pending |
| `MONOBANK_PENDING_LOOKBACK_DAYS` | 3 | Days a forward fetch re-reads (1 to 7) |
| `MONOBANK_API_BASE_URL` | https://api.monobank.ua | Only that host or a loopback host (tests, `script/monobank_fake`) |
