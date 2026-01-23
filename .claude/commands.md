# Commands Reference

## Development

```bash
bin/dev                # Start full dev environment (Rails, Sidekiq, Tailwind CSS watcher)
bin/rails console      # Open Rails console
bin/setup              # Initial project setup (dependencies + database)
```

## Testing

```bash
bin/rails test                              # Run all tests
bin/rails test:db                           # Run tests with database reset
bin/rails test:system                       # System tests only (use sparingly)
bin/rails test test/models/account_test.rb  # Specific test file
bin/rails test test/models/account_test.rb:42  # Specific test at line
```

## Linting & Formatting

```bash
bin/rubocop                    # Ruby linter
bin/rubocop -f github -a       # Ruby linter with auto-correct (for PRs)
bundle exec erb_lint ./app/**/*.erb -a  # ERB linting with auto-correct
npm run lint                   # Check JS/TS code
npm run lint:fix               # Fix JS/TS issues
npm run format                 # Format JS/TS code
bin/brakeman --no-pager        # Security analysis
```

## Database

```bash
bin/rails db:prepare    # Create and migrate database
bin/rails db:migrate    # Run pending migrations (ask before running)
bin/rails db:rollback   # Rollback last migration
bin/rails db:seed       # Load seed data
```

## Pre-PR Checklist

Run all of these before opening a pull request:

```bash
bin/rails test                           # Required
bin/rails test:system                    # When applicable
bin/rubocop -f github -a                 # Required
bundle exec erb_lint ./app/**/*.erb -a   # Required
bin/brakeman --no-pager                  # Required
```

Only proceed if ALL checks pass.
