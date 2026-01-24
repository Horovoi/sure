# Testing Guidelines

## Core Rules

- **Always use Minitest + fixtures** (never RSpec or factories)
- Keep fixtures minimal (2-3 per model for base cases)
- Create edge cases on-the-fly within test context
- System tests sparingly (they're slow)
- VCR for external API testing
- Test helpers in `test/support/`

## What to Test

**Do test:**
- Critical domain business logic
- Command boundaries (verify called with correct params)
- Query outputs

**Don't test:**
- ActiveRecord/Rails functionality
- Implementation details of other classes
- Obvious getters/setters

## Examples

```ruby
# GOOD - Testing critical domain business logic
test "syncs balances" do
  Holding::Syncer.any_instance.expects(:sync_holdings).returns([]).once
  assert_difference "@account.balances.count", 2 do
    Balance::Syncer.new(@account, strategy: :forward).sync_balances
  end
end

# BAD - Testing ActiveRecord functionality
test "saves balance" do
  balance_record = Balance.new(balance: 100, currency: "USD")
  assert balance_record.save
end
```

## Stubs and Mocks

- Use `mocha` gem
- Prefer `OpenStruct` for mock instances
- Only mock what's necessary

```ruby
# Mocking external dependencies
PlaidClient.any_instance.expects(:get_transactions).returns(mock_response)

# Using OpenStruct for simple mocks
mock_account = OpenStruct.new(id: 1, balance: 1000)
```

## Running Tests

```bash
bin/rails test                              # All tests
bin/rails test test/models/account_test.rb  # Specific file
bin/rails test test/models/account_test.rb:42  # Specific line
bin/rails test:system                       # System tests (slow)
```

## Docker Database Setup

The database runs in Docker. `.env.test.local` must exist with DB credentials:

```bash
# Required in .env.test.local
DB_HOST=127.0.0.1
DB_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
```

**Why?** `dotenv-rails` intentionally skips `.env.local` in test environment for safety. Without `.env.test.local`, tests fail with `ActiveRecord::DatabaseConnectionError`.
