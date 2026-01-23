# Project Conventions

## 1. Minimize Dependencies

- Push Rails to its limits before adding dependencies
- Require strong technical/business justification for new gems
- Favor old and reliable over new and flashy

## 2. Skinny Controllers, Fat Models

- Business logic in `app/models/`, avoid `app/services/`
- Use Rails concerns and POROs for organization
- Models answer questions about themselves:

```ruby
# GOOD
account.balance_series

# BAD
AccountSeries.new(account).call
```

## 3. Database vs ActiveRecord Validations

| Type | Where |
|------|-------|
| Simple (null checks, unique indexes) | Database |
| Form convenience validations | ActiveRecord (prefer client-side) |
| Complex business logic | ActiveRecord |

## 4. Optimize for Simplicity

- Prioritize good OOP domain design over premature optimization
- Focus performance efforts on:
  - N+1 queries (always fix these)
  - Global layouts (affects every page)

## 5. Code Organization

**Models:** Domain logic, queries, business rules
**Concerns:** Shared behavior across models
**POROs:** Complex operations that don't fit in models
**Components:** Reusable UI with logic
**Partials:** Simple, static template fragments

## 6. Naming Conventions

Follow Rails conventions:
- Models: singular (`Account`, `Transaction`)
- Controllers: plural (`AccountsController`)
- Tables: plural snake_case (`accounts`, `transactions`)
- Foreign keys: `model_id` (`account_id`)

## 7. Error Handling

- Let exceptions bubble up unless you can handle them meaningfully
- Use Rails' built-in error handling for common cases
- Log errors with context for debugging
