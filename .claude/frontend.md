# Frontend Guidelines

## Stack Overview

- **Hotwire**: Turbo + Stimulus for reactive UI
- **ViewComponents**: Reusable UI in `app/components/`
- **Tailwind CSS v4.x**: Custom design system
- **D3.js**: Financial visualizations (time series, donut, sankey)

## Hotwire-First Principles

1. **Native HTML over JS components**
   - Use `<dialog>` for modals
   - Use `<details><summary>` for disclosures

2. **Turbo frames** for page sections over client-side solutions

3. **Query params for state** over localStorage/sessions

4. **Server-side formatting** for currencies, numbers, dates

## Tailwind Design System

**Always reference:** `app/assets/tailwind/maybe-design-system.css`

**Use functional tokens:**
```css
/* GOOD */
text-primary, bg-container, border-primary

/* BAD */
text-white, bg-white, border-gray-200
```

**Rules:**
- Never create new styles in design system without permission
- Always generate semantic HTML
- Use `icon` helper for icons, **never** `lucide_icon` directly

## ViewComponents vs Partials

**Use ViewComponents when:**
- Complex logic or styling patterns
- Reused across multiple views
- Needs variants/sizes
- Requires Stimulus controllers
- Has configurable slots
- Needs accessibility/ARIA support

**Use Partials when:**
- Primarily static HTML
- Used in one or few contexts
- Simple template content
- No variants needed

**Rules:**
- Prefer components over partials when available
- Keep domain logic OUT of view templates
- Logic belongs in component files, not templates

## Stimulus Controllers

**Declarative actions (required):**
```erb
<div data-controller="toggle">
  <button data-action="click->toggle#toggle" data-toggle-target="button">
    <%= t("components.example.show") %>
  </button>
  <div data-toggle-target="content" class="hidden">
    <!-- content -->
  </div>
</div>
```

**Best practices:**
- Keep controllers lightweight (< 7 targets)
- Single responsibility
- Component controllers in component directory
- Global controllers in `app/javascript/controllers/`
- Pass data via `data-*-value` attributes, not inline JS

## Internationalization (i18n)

**All user-facing strings must use i18n.**

**Key organization:**
```yaml
en:
  accounts:
    index:
      title: "Accounts"
  components:
    transaction_details:
      show_details: "Show Details"
      amount_label: "Amount"
```

**Usage:**
```erb
<%= t("accounts.index.title") %>
<%= t("users.greeting", name: user.name) %>
<%= t("transactions.count", count: @transactions.count) %>
```

**Rules:**
- Hierarchical keys by feature: `accounts.index.title`
- Descriptive key names: `show_details` not `button`
- Update `config/locales/en.yml` for new strings
