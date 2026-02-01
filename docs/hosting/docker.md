# Self Hosting Sure with Docker

This guide covers setting up, updating, and maintaining a self-hosted Sure instance with Docker Compose.

## Setup Guide

### Step 1: Install Docker

1. Install Docker Engine by following [the official guide](https://docs.docker.com/engine/install/)
2. Start the Docker service
3. Verify Docker is running:

```bash
docker run hello-world
```

### Step 2: Create a directory and download the compose file

```bash
mkdir -p ~/docker-apps/sure
cd ~/docker-apps/sure

# Download the compose file
curl -o compose.yml https://raw.githubusercontent.com/horovoi/sure/main/compose.example.yml
```

### Step 3: Configure your environment

#### Create the environment file

```bash
curl -o .env https://raw.githubusercontent.com/horovoi/sure/main/.env.example
```

#### Set required variables

Open `.env` in a text editor and set these two values:

```txt
SECRET_KEY_BASE="<generated-key>"
POSTGRES_PASSWORD="<your-database-password>"
```

Generate `SECRET_KEY_BASE` with:

```bash
openssl rand -hex 64
```

Or without openssl:

```bash
head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' && echo
```

#### Optional variables

The `.env.example` file documents all supported variables. Key optional categories:

- **Exchange rates** — `EXCHANGE_RATE_PROVIDER` (options: `yahoo_finance`, `twelve_data`, `nbu`). Yahoo Finance is the default and requires no API key. Use `nbu` for official National Bank of Ukraine rates if your accounts use UAH
- **Brand Fetch** — `BRAND_FETCH_CLIENT_ID` for displaying logos for banks, merchants, and subscription services. Get a client ID at [brandfetch.com](https://brandfetch.com)
- **OpenAI** — `OPENAI_ACCESS_TOKEN` for AI chat and rules features (incurs API costs)
- **SMTP** — `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `EMAIL_SENDER` for password resets and email reports
- **Market data** — `SECURITIES_PROVIDER` for stock prices (options: `yahoo_finance`, `twelve_data`). `TWELVE_DATA_API_KEY` required if using Twelve Data
- **OIDC** — `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER` for OpenID Connect authentication
- **Storage** — Amazon S3, Cloudflare R2, or generic S3 for file uploads (defaults to local disk)
- **Custom port** — `PORT=3000` if you need a different port

#### Using HTTPS

If you access your instance over HTTPS (e.g., behind a reverse proxy with SSL), edit `compose.yml` and change:

```yaml
RAILS_ASSUME_SSL: "true"
```

### Step 4: Run the app

Start the app to verify everything works:

```bash
docker compose up -d
```

Verify it's running:

```bash
docker compose ls
```


Open `http://localhost:3000` in your browser. You should see the login screen.

### Step 5: Create your account

On the login page, click "create your account" and register with your email and password.

## How to update

The app uses pre-built images from GHCR. By default, the compose file uses `ghcr.io/horovoi/sure:latest`.

To update:

```bash
cd ~/docker-apps/sure
docker compose pull
docker compose up -d
```

To pin a specific version, edit the `image:` lines in `compose.yml` and replace `latest` with a commit SHA tag (see [packages](https://github.com/horovoi/sure/pkgs/container/sure) for available tags).

## Backups

The compose file includes an optional backup service using `postgres-backup-local`. To enable it:

1. Edit `compose.yml` and change the backup volume path (`/opt/sure-data/backups`) to your preferred location
2. Start with the backup profile:

```bash
docker compose --profile backup up -d
```

By default, backups run daily and retain 7 daily, 4 weekly, and 6 monthly snapshots.

## Optional configuration

### Brand Fetch (merchant and subscription icons)

To display logos for banks, merchants, and subscription services, set `BRAND_FETCH_CLIENT_ID` in your `.env` file. Get a client ID at [brandfetch.com](https://brandfetch.com).

You can also configure this in the self-hosting settings UI at `/settings/hosting`.

Optional settings:

- `BRAND_FETCH_HIGH_RES_LOGOS=true` — fetches 120x120 icons instead of the default 40x40
- **Cache All Icons** button in the settings page downloads icons locally so they load without external requests

### Ukrainian Hryvnia (UAH) users

If your accounts use UAH as their currency, set the exchange rate provider to **National Bank of Ukraine** for accurate UAH rates:

- In the UI: go to `/settings/hosting` and select "National Bank of Ukraine (UAH)" as the exchange rate provider
- Or in `.env`: set `EXCHANGE_RATE_PROVIDER=nbu`

The NBU provider is free and fetches official rates from the National Bank of Ukraine. Non-UAH currency pairs (e.g., USD/EUR) automatically fall back to Yahoo Finance.

## Troubleshooting

### ActiveRecord::DatabaseConnectionError

If you run into database connection issues on **first startup**, it is likely because Docker initialized Postgres with a different default role from a previous attempt.

You can **reset the database** (this deletes existing Sure data):

```bash
docker compose down
docker volume rm sure_postgres-data
docker compose up
docker compose exec db psql -U sure_user -d sure_production -c "SELECT 1;"
```

### Slow .csv import

Importing CSV files requires the worker container to communicate with Redis. Check worker logs for connection timeouts or Redis communication failures.
