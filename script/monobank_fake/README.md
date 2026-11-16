# Fake monobank

A fake of monobank's personal API (<https://api.monobank.ua/docs/>) that speaks the real
wire format, for tests and for a full run on the staging copy. Nothing here talks to the
real bank.

| File | What it is |
|---|---|
| `app.rb` | `MonobankFake::App`, the fake (Rack + Ruby standard library, no Rails) |
| `config.ru`, `server` | run the fake as a server on 127.0.0.1 |
| `fixtures/sample.json` | sample client: UAH black card with a credit limit, USD and EUR accounts, FOP, two jars (one with a target); purchases, a refund, own transfers, two holds; the first statement request gets a 429, the first EUR one a 500; two rounds of jar renames and target changes |
| `fixture_generator.rb`, `generate_fixture.rb` | build a fixture around a real hand-kept account (staging copy) |
| `checks.rb`, `drain.rb`, `scenario.rb` | the run and its checks, shared by `e2e.rb` and the integration test |
| `e2e.rb` | the full run on the staging copy |

Tests: `test/lib/monobank_fake/*_test.rb` (the fake, the drain, the generator, the guards),
`test/integration/monobank_end_to_end_test.rb` (the full run in the test database, with
travel in time). Test helper: `with_monobank_fake(fixture) { |fake| ... }`
(`test/support/monobank_fake_helper.rb`) serves the fake on `http://127.0.0.1:4599`
through WebMock and sets `MONOBANK_API_BASE_URL`.

## What the fake does

| Request | Answer |
|---|---|
| `GET /personal/client-info` | `{clientId, name, webHookUrl, permissions, accounts: [...], jars: [...]}` |
| `GET /personal/statement/{account}/{from}[/{to}]` | rows with `from <= time <= to`, newest first, at most 500; `to` defaults to now; account `0` is the first card |
| no `X-Token` header | 401 |
| unknown `X-Token` | 403 `{"errorDescription": "Unknown 'X-Token'"}` |
| a second request to the same function with the same token within `rate_limit_seconds` | 429 `{"errorDescription": "Too many requests"}` (marked `early` in the log; it does not restart the timer) |
| window longer than 2,682,000 s (31 days + 1 hour), `to < from`, unknown account | 400 `{"errorDescription": ...}` |

Every request that passes the token check counts for the rate limit, also one that then
gets a 400 or a fault. A row without `balance` gets the balance after it: the account's
balance for the newest row, then each older row the newer balance minus the newer amount
(holds count, as in the bank's balance).

Admin endpoints, only with the header `X-Fake-Admin: 1` (404 without it), JSON bodies:

| Request | Effect |
|---|---|
| `POST /__fake/settle_hold {account, hold_id, settled_id?, amount?, time?}` | the hold becomes a settled row: by default the same id with `hold: false`; with `settled_id` a new id. A different amount moves the balance by the difference |
| `POST /__fake/cancel_hold {account, hold_id}` | the hold disappears and its amount returns to the balance |
| `POST /__fake/add {account, item}` | a new row (dated now unless it has `time` or `days_ago`, counted from now); the balance moves by its amount |
| `POST /__fake/update_jar {jar, title?, goal?}` | the jar gets a new title or target (minor units; `null` removes it); keys not given stay |
| `POST /__fake/reset` | back to the fixture; log and rate limits cleared; `days_ago` counted from now |
| `GET /__fake/log` | every request: `at` (epoch seconds), `method`, `path`, `function`, `token`, `account`, `from`, `to`, `status`, `rows`, `early`, `fault`, `since_previous` |
| `GET /__fake/state` | accounts and jars with their current balances, row counts |

The same operations are Ruby methods on the app: `settle_hold!`, `cancel_hold!`,
`add_item!`, `update_jar!`, `reset!`, `requests`, `early_requests`, `balance(id)`, `statement(id)`.

## Fixture format

```json
{
  "tokens": ["e2e-fake-token"],
  "rate_limit_seconds": 60,
  "client": {"clientId": "fakeClient01", "name": "Тестовий Клієнт", "permissions": "psfj"},
  "accounts": [{"id": "mbf-uah-black", "currencyCode": 980, "type": "black", "balance": 4200000,
                "creditLimit": 5000000, "maskedPan": ["537541******1234"], "iban": "UA..."}],
  "jars": [{"id": "mbf-jar-vacation", "title": "Відпустка", "currencyCode": 980, "balance": 150000, "goal": 2000000}],
  "statements": {
    "mbf-uah-black": [{"id": "mbf-new-atb", "days_ago": 0.55, "description": "АТБ-Маркет", "mcc": 5411,
                       "amount": -61250, "_group": "groceries", "_category": "Groceries"}]
  },
  "faults": [{"path_prefix": "/personal/statement/mbf-eur", "status": 500, "times": 1}],
  "expected": {"link": {"account_name": "Mono Visa", "monobank_account_id": "mbf-uah-black"}, "claims": 4}
}
```

- Amounts and balances are minor units (kopecks, cents), signed as the bank signs them:
  negative is money out.
- `rate_limit_seconds` (default 60): seconds between two requests of one token to one
  function. `MONOBANK_FAKE_RATE_LIMIT_SECONDS` overrides it, the app's
  `rate_limit_seconds:` keyword (and the server's `--rate-limit-seconds`) override both.
  0 turns the limit off.
- Accounts: missing fields default to `sendId ""`, `currencyCode 980`, `cashbackType "UAH"`,
  `balance 0`, `creditLimit 0`, `maskedPan []`, `type "black"`, `iban ""`. Jars: `sendId ""`,
  `title "Банка"`, `description ""`, `currencyCode 980`, `balance 0`, `goal null`.
- Rows need `amount` and `time` (Unix seconds) or `days_ago` (days before the fake
  started; wins over `time`). Defaults: `id` generated, `description ""`, `mcc 0`,
  `originalMcc = mcc`, `hold false`, `operationAmount = amount`, `currencyCode` = the
  account's, `commissionRate 0`, `cashbackAmount 0`, `balance` computed. `comment`,
  `receiptId`, `invoiceId`, `counterEdrpou`, `counterIban`, `counterName` are sent only
  when present.
- Keys starting with `_` are notes and are never sent:
  - `_manual: {shift_days, name, entry_id}`: the owner also entered this row by hand,
    dated `shift_days` days from the bank's date; the run expects the bank row to claim
    that entry. `_entry_id`: the entry's id (the generator and the integration test set it).
  - `_group`, `_category`: the MCC group the row belongs to and the category name the new
    entry must get (`null`: no category, e.g. own transfers).
- `faults`: answered instead of the real response for requests whose path starts with
  `path_prefix`, `times` times (default 1, `null` for always), with `status` and `body`
  (default `{"errorDescription": "Fake fault"}`), or `raise` one of `Errno::ECONNRESET`,
  `Errno::ECONNREFUSED`, `EOFError`, `Timeout::Error`.
- `jar_goal_rounds` (read by the scenario, not by the fake): rounds after the holds. Each
  round has `bank` (`{jar, title?, goal?}`: what changes at the fake), `owner`
  (`{jar, target?, name?}`: the owner edits that jar's goal in Sure, `target` in major
  units), and `expected` (the round's `jar_goals`). The scenario syncs and checks each round.
- `expected` (read by the checks, not by the fake):

| Key | Checked |
|---|---|
| `link.account_name`, `link.monobank_account_id`, `link.cutover_date` | the account linked to that product (`"auto"`: default cutover) |
| `cutover_date`, `cutover_adjustment` | the stored cutover; the cutover day's `cash_adjustments` (generated fixtures: 0) |
| `claims` | hand-entered entries claimed by bank rows (each `_manual` row joined its entry) |
| `skipped_before_cutover` | bank rows dated before the cutover, not hand-entered, so not imported |
| `never_imported` | row ids that must have no entry (older than the first fetch window) |
| `pending`, `pending_ids` | pending entries from holds |
| `transfers`, `transfer_pairs` | pending transfer suggestions `{outflow, inflow}` (row ids), legs still `standard` |
| `exchange_rates` | rates the cross-currency rows were priced at (the test and the staging run add them when missing) |
| `balances` | each product's account balance after the run (credit card: amount owed) |
| `account_types` | accountable type per product |
| `categories`, `category_names` | per MCC group, how many new entries get that category |
| `jar_goals` | per jar: `{name, target}` (major units) for the one goal funded by the whole jar account, linked to the jar; `null`: no goal. No card or currency account has a goal |

## Commands

Run the fake by itself:

```bash
script/monobank_fake/server --port 4599 [--fixture file.json] [--rate-limit-seconds 60]
curl -H 'X-Token: e2e-fake-token' http://127.0.0.1:4599/personal/client-info
curl -H 'X-Fake-Admin: 1' http://127.0.0.1:4599/__fake/log
```

Point a development app at it (with `BANK_CONNECTIONS_ENABLED=monobank`, token `e2e-fake-token`):

```bash
MONOBANK_API_BASE_URL=http://127.0.0.1:4599 bin/dev
```

Build a fixture around the staging copy of Mono Visa (reads only):

```bash
bin/staging run bin/rails runner script/monobank_fake/generate_fixture.rb -- --account "Mono Visa" --out tmp/monobank_fixture.json
```

Full run on the staging copy (changes the copy; `bin/staging refresh` resets it):

```bash
BANK_CONNECTIONS_ENABLED=monobank bin/staging run bin/rails runner script/monobank_fake/e2e.rb -- --account "Mono Visa"
```

It syncs Mono Visa first (the copy's balance rows can lag its entries), builds a fixture
from it (or takes `--fixture`), adds the fixture's exchange rates the copy has none of (and
removes them at the end), starts the fake on a free 127.0.0.1 port with one request per
second per function (`MONOBANK_MIN_REQUEST_INTERVAL=1`),
connects monobank, links Mono Visa, creates accounts for the other products, runs every job
itself in due order (sleeping until scheduled ones are due), then settles one hold and
cancels the other, then plays the fixture's `jar_goal_rounds` (rename a jar, move a
target, edit a goal as the owner), then runs the hourly sync. It prints PASS or FAIL for each check:

- no duplicates: no external id twice; no hand-entered entry left next to a new bank entry
  with the same amount within 3 days
- balances before the cutover identical to the snapshot; hand-entered entries keep their
  dates and amounts; no adjustment on the cutover day
- current balance and account type of every product
- pending holds; after the settle and cancel: no pending, the settled hold a plain entry,
  the cancelled one gone, balances moved
- claims and rows skipped before the cutover as expected; rows older than the fetch window
  never imported
- transfer suggestions for card -> jar, jar -> card, UAH -> USD, FOP -> card
- categories per MCC group
- jar goals: the jar with a target is one goal funded by its whole account; the jar
  without a target has none, until it gets one; a rename and a new target in monobank
  reach the goal, and the owner's own target and name stay while monobank's do not move
- 0 requests before the rate limit allowed them, requests at least the interval apart
- each fixture fault (the 429, the 500) served as often as it says, then the real answers
- no sync open longer than 30 minutes, none failed or stale; statement fetching finished
- the hourly sync with nothing new asks client-info once and no statement

Exit status 1 when any check fails. Both scripts refuse to run unless the database is the
staging copy (`DB_PORT=5433`, which `bin/staging run` sets) and the environment is not
production; the generator also runs in the test environment. While `e2e.rb` runs, every
HTTP request to a host other than 127.0.0.1, localhost or ::1 is refused.

The integration test runs the same scenario on the sample fixture:

```bash
bin/rails test test/integration/monobank_end_to_end_test.rb   # MONOBANK_E2E_VERBOSE=1 prints every job
```
