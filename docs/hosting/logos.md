# Account, Merchant and Security Logos

Sure has integration with the [Brand Fetch Logo Link](https://brandfetch.com/developers/logo-api) service to provide logos for accounts, merchants and securities.
Logos are currently matched in the following ways:

- For accounts, Plaid integration for the account is required and matched via FQDN (fully qualified domain name) from the Plaid integration
- For merchants, OpenAI integration is required and automatically matched to the merchant name and matched via FQDN
- For securities, logos are matched using the ticker symbol

> [!NOTE]
> Currently ticker symbol matching cannot specify the exchange and since US exchanges are prioritized, securities from other exchanges might not have the right logo.

## Enabling Brand Fetch Integration

A Brand Fetch Client ID is required and to obtain a client ID, sign up for an account [here](https://brandfetch.com/developers/logo-api).

Once you enter the Client ID into the Sure settings under the `Self-Hosting` section, logos from Brand Fetch integration will be enabled.
Alternatively, you can provide the client id using the `BRAND_FETCH_CLIENT_ID` environment variable to the web and worker services.

![CLIENT_ID screenshot](logos-clientid.png)

---

## Subscription Service Icon Caching

Subscription services (Netflix, Spotify, etc.) use Brandfetch icons. To reduce API calls and stay within Brandfetch's free tier (500k requests/month), icons are cached locally using Active Storage.

### How It Works

```
First request:  Server → Brandfetch CDN → download → Active Storage
Subsequent:     Browser → Rails → Active Storage (no API call)
```

1. When a subscription is created with a service, the icon is fetched in the background
2. Icons are stored in Active Storage and served locally thereafter
3. The `logo_url` method automatically returns the cached path if available

### Key Files

| File | Purpose |
|------|---------|
| `app/models/subscription_service.rb` | `has_one_attached :icon`, `logo_url` method |
| `app/jobs/cache_subscription_icon_job.rb` | Background job to fetch and cache icons |
| `lib/tasks/subscription_services.rake` | Rake tasks for bulk operations |

### Commands

**Cache all icons** (run after deployment or after seeding services):
```bash
bin/rails subscription_services:cache_icons
```

**Seed subscription services** (adds 300+ popular services):
```bash
bin/rails subscription_services:seed
```

**Check caching status:**
```bash
# Count of cached icons
bin/rails runner "puts SubscriptionService.joins(:icon_attachment).count"

# Count of uncached icons
bin/rails runner "puts SubscriptionService.left_joins(:icon_attachment).where(active_storage_attachments: { id: nil }).count"
```

### Deployment Checklist

1. Deploy the application
2. Run `bin/rails subscription_services:seed` (if not already seeded)
3. Run `bin/rails subscription_services:cache_icons`
4. Ensure Sidekiq is running to process jobs
5. New subscriptions will auto-cache icons going forward

> [!NOTE]
> The caching job requires Sidekiq to be running. In development, `bin/dev` starts Sidekiq automatically via Procfile.dev.
