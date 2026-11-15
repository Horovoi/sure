# Architecture Overview

## Application Modes

The app runs in two modes:
- **Managed**: Team operates servers for users (`Rails.application.config.app_mode = "managed"`)
- **Self Hosted**: Users run on their own infrastructure via Docker Compose (`app_mode = "self_hosted"`)

This copy runs self hosted on one machine. See [deploy.md](deploy.md) for how it is deployed.

## Core Domain Model

```
User → has many Accounts → has many Transactions
                        → has many Balances

Account types: checking, savings, credit cards, investments, crypto, loans, properties

Transaction → belongs to Category
           → can have Tags and Rules

Investment accounts → have Holdings → track Securities via Trades
```

## API Architecture

**Internal API:**
- Controllers serve JSON via Turbo for SPA-like interactions
- Jbuilder templates for JSON rendering

**External API (`/api/v1/`):**
- Doorkeeper OAuth for third-party apps
- API keys with JWT tokens for direct access
- Scoped permissions system
- Rate limiting via Rack Attack (configurable per API key)

## Sync & Import System

### Plaid Integration (Real-time syncing)
- `PlaidItem` manages bank connections
- `Sync` tracks sync operations
- Background jobs handle data updates
- Config: `config/initializers/plaid_config.rb`

### CSV Import (Manual)
- `Import` manages import sessions
- Supports transaction and balance imports
- Custom field mapping with transformation rules

### Pending Transactions (Plaid)
- Stored at `Transaction#extra["plaid"]["pending"]`
- UI shows "Pending" badge when `transaction.pending?` is true
- Disable with `PLAID_INCLUDE_PENDING=0`

## Background Processing

Sidekiq handles:
- `SyncJob` - Account syncing
- `ImportJob` - Import processing
- `AssistantResponseJob` - AI chat responses
- Scheduled tasks via sidekiq-cron

## Multi-Currency Support

- Monetary values stored in user's base currency
- `Money` objects handle conversion and formatting
- Historical exchange rates for accurate reporting

## MCP Endpoint (`/mcp`)

Claude Code (and the in-app Claude chat, through the host bridge) reads and changes Sure's data over the
Model Context Protocol. The endpoint serves protocol **2026-07-28 only**, statelessly, with tools only,
through the official `mcp` gem (`MCP::Server::Transports::StreamableHTTPTransport`, `stateless: true`).

- `McpController#handle`: one POST endpoint. GET and DELETE answer 405 (`Allow: POST`).
  Before-actions, in order: bearer `MCP_API_TOKEN` (SHA256-digest compare, 401 with
  `WWW-Authenticate: Bearer realm="sure"`), the active user from `MCP_USER_EMAIL`, the
  Settings > Self-Hosting switch `Setting.mcp_enabled` (403 when off; static token only), a foreign `Origin`
  gets 403 (no `Origin` and the same origin pass), `Mcp-Session-Id` and `Last-Event-ID` are dropped
  (never echoed), the version gate (`initialize` or a missing or other `MCP-Protocol-Version` gets 400
  with JSON-RPC -32022 and `data.supported`), then the family time zone wraps the request.
- The SDK enforces the rest: `Mcp-Method` / `Mcp-Name` (Base64 sentinel decoded) and the header/`_meta`
  version match (400, -32020), the required `_meta` envelope (400, -32602), unknown method (404, -32601),
  unknown tool (400, -32602), notifications (202, no body), `resultType`, and the cache hints.
- `Mcp::ServerBuilder.build(credential)`: one `MCP::Tool` per `Assistant.function_classes` entry, in the
  same order as the chat. A tool returns its result as a JSON text block plus `structuredContent`; a
  failure is an `isError` result built by `Assistant::FunctionToolCaller.error_result` (the full
  exception goes only to the log). `tools/list` and `server/discover` carry `ttlMs` 60000 and
  `cacheScope` private (the schemas hold family names).
- Read tools: `get_accounts` (ids, loan and card `terms`, opt-in balance series), `get_balance_sheet`
  (named or custom period, interval), `get_income_statement` (budget-month series, previous period,
  account filter; totals match `IncomeStatement`), `get_transactions` (one row per transfer,
  `classification` income/expense/transfer, compact rows), `get_holdings`, `get_valuations`,
  `get_categories`, `get_tags`, `get_merchants`, `search_family_files`. Filters take exact names from the
  get_* tools, not enums. A soft failure is `{error, hint}`, like a raised one.
- Scope tags: each `Assistant::Function` declares `scope_tag :read` (default), `:write` or `:destructive`.
  `#mcp_annotations` follow the tag (read gives readOnlyHint, destructive gives destructiveHint; a tool
  overrides `#idempotent?` / `#open_world?`). `#mcp_input_schema` makes nullable properties optional and
  prunes empty enums. Write tools return the changed record `id`/`ids`, name their `record_type`, and
  define `audit_before(params)` (state before the call) for the tool-call audit.
- `Assistant.function_classes_for(scope)`: `:full` is every tool in the fixed order of
  `Assistant.function_classes`; `:read` keeps only read tools. The chat (`Assistant::Configurable`) and both
  MCP tokens use `:full`: every tool, writes and deletes included, no approval prompt.
- `Mcp::Credential`: who is calling (user, kind `:static` or `:turn`, scope, assistant message). The scope
  picks the tools the server registers, so a tool outside it is an unknown tool (-32602). The credential
  also feeds the tool-call audit.
- Rack::Attack throttles `/mcp` at 300 requests a minute per IP.

**Clients.** Claude Code 2.1.325 or newer is the minimum CLI version: it is the first version found to
carry the 2026-07-28 client (`server/discover`, the `_meta` envelope); older CLIs speak only the
handshake protocol and get -32022. The claude bridge reads this minimum. Confirm a new CLI with
`claude --debug` against staging (the log shows `server/discover` and protocol 2026-07-28).

Production is registered once by the claude bridge installer. By hand it is:

```bash
claude mcp add --scope user --transport http sure http://localhost:3333/mcp \
  --header "Authorization: Bearer $MCP_API_TOKEN"
```

Staging (http://localhost:3334) reads the same `.env.production`, so it takes the same token. The
project `.mcp.json` registers it as `sure-staging` and reads the token from `SURE_STAGING_MCP_TOKEN`
in your shell; no secret is in the repository:

```bash
export SURE_STAGING_MCP_TOKEN=...   # the MCP_API_TOKEN value from .env.production
bin/staging up && claude --debug    # then /mcp shows sure-staging
```
