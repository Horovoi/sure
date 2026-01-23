# Architecture Overview

## Application Modes

The app runs in two modes:
- **Managed**: Team operates servers for users (`Rails.application.config.app_mode = "managed"`)
- **Self Hosted**: Users run on their own infrastructure via Docker Compose (`app_mode = "self_hosted"`)

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
