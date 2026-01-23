# Sure - Personal Finance Manager

Rails application for personal finance management with Plaid integration, multi-currency support, and AI-powered insights.

## Quick Start

```bash
bin/dev              # Start development (Rails + Sidekiq + Tailwind)
bin/rails console    # Rails console
bin/rails test       # Run tests
```

## Critical Rules

**Authentication context:**
- Use `Current.user` (not `current_user`)
- Use `Current.family` (not `current_family`)

**Never run these commands:**
- `rails server` / `rails s` (use `bin/dev` instead)
- `rails credentials:edit`
- `rails db:migrate` (ask first)
- `touch tmp/restart.txt`

## Before Opening a PR

Run all checks: `bin/rails test && bin/rubocop -a && bundle exec erb_lint ./app/**/*.erb -a && bin/brakeman --no-pager`

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.

## Documentation

- [Commands Reference](.claude/commands.md) - All development commands
- [Architecture](.claude/architecture.md) - Domain model, APIs, sync system
- [Frontend Guidelines](.claude/frontend.md) - Hotwire, components, Tailwind, i18n
- [Testing](.claude/testing.md) - Testing philosophy and examples
- [Conventions](.claude/conventions.md) - Project conventions and patterns
