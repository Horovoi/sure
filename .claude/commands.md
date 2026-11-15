# Commands Reference

## Development

```bash
bin/dev                # Start full dev environment (Rails, Sidekiq, Tailwind CSS watcher)
bin/rails console      # Open Rails console
bin/setup              # Initial project setup (dependencies + database)
```

Development enqueues jobs into Sidekiq, as production does, so `bin/dev` and
`bin/rails console` need Redis on `REDIS_URL` (default `redis://localhost:6379`).
The `worker` process in `Procfile.dev` runs the jobs. `bin/staging dev` points
`REDIS_URL` at the staging Redis on port 6380 instead.

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

## Deploy and Staging

See [deploy.md](deploy.md) for what these do and the rules around them.

```bash
bin/deploy                      # Build the current commit, rehearse on a copy, back up, migrate, start
bin/deploy --rollback <ref>     # Switch back to an earlier image (does not undo migrations)
bin/staging refresh             # Replace the staging copy with fresh production data
bin/staging up [<ref>]          # Run a version on the copy at http://localhost:3334
bin/staging up --build          # Build the working tree and run that on the copy
bin/staging dev                 # bin/dev with hot reload on the copy
bin/staging run <command...>    # Run a command against the copy (e.g. bin/rails console)
bin/staging bench <old> <new>   # Compare page speed of two versions on the copy
bin/staging down                # Stop staging
```

## Pre-PR Checklist

Run this before opening a pull request:

```bash
bin/ci   # autoloading, rubocop, erb_lint, brakeman, tests, system tests (about 1.5 minutes)
```

The steps are listed in `config/ci.rb`. Only proceed if ALL of them pass.
