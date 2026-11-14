# Sure - Personal Finance Manager

Rails application for personal finance management with Plaid integration, multi-currency support, and AI-powered insights.

## Quick Start

```bash
bin/dev              # Start development (Rails + Sidekiq + Tailwind)
bin/rails console    # Rails console
bin/rails test       # Run tests
bin/deploy           # Build the current commit and run it as production on this machine
bin/staging up       # Run a version on a private copy of production (http://localhost:3334)
```

Production runs locally in Docker at http://localhost:3333. Read [Deploy and Staging](.claude/deploy.md) before deploying or touching Docker.

## Critical Rules

**Authentication context:**
- Use `Current.user` (not `current_user`)
- Use `Current.family` (not `current_family`)

**Never run these commands:**
- `rails server` / `rails s` (use `bin/dev` instead)
- `rails credentials:edit`
- `rails db:migrate` (ask first)
- `touch tmp/restart.txt`
- `docker compose down -v` on the `sure` project, or anything else that deletes the `sure_*` volumes (production data)
- `docker push`, or any build that pushes an image to a registry

**Deploy:**
- Deploy only when asked, with `bin/deploy` (never by hand with `docker compose`)
- Migrations in production are run by `bin/deploy` only
- To test against real data, use `bin/staging`, never production

## Before Opening a PR

Run all checks: `bin/rails test && bin/rubocop -a && bundle exec erb_lint ./app/**/*.erb -a && bin/brakeman --no-pager`

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.

## Documentation

- [Commands Reference](.claude/commands.md) - All development commands
- [Deploy and Staging](.claude/deploy.md) - How production runs, deploying, the staging copy, benchmarks
- [Architecture](.claude/architecture.md) - Domain model, APIs, sync system
- [Frontend Guidelines](.claude/frontend.md) - Hotwire, components, Tailwind, i18n
- [Testing](.claude/testing.md) - Testing philosophy and examples
- [Conventions](.claude/conventions.md) - Project conventions and patterns
