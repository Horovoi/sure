# Self Hosting Sure with Docker

This guide helps you set up, run, and update your self-hosted Sure instance using Docker Compose. Docker Compose is the most popular and recommended way to self-host the Sure app.

## Setup Guide

Follow the steps below to get your app running.

### Step 1: Install Docker

Complete the following steps:

1. Install Docker Engine using the official guide: https://docs.docker.com/engine/install/ (for Windows and macOS, you can use Docker Desktop app instead: https://docs.docker.com/desktop/)
2. Start the Docker service on your machine
3. Verify Docker is installed and running:

```bash
docker run hello-world
```

### Step 2: Create a folder and get the compose file

Create a working directory for your deployment and download the compose file:

```bash
mkdir -p ~/docker-apps/sure
cd ~/docker-apps/sure

# Download the production compose file
curl -o docker-compose.yml \
  https://raw.githubusercontent.com/Horovoi/sure/refs/heads/main/docker-compose.prod.yml
```

This fetches the production compose configuration that the rest of this guide references.

### Step 3: Configure your environment

Create a `.env` file next to `docker-compose.yml` for Docker Compose variable substitution.

```bash
touch .env
```

Generate a `SECRET_KEY_BASE` (required):

```bash
openssl rand -hex 64
# or, if openssl isn't available
head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' && echo
```

Open `.env` and set at least the required values:

```dotenv
# Required
SECRET_KEY_BASE="paste_the_generated_value_here"
POSTGRES_PASSWORD="choose_a_strong_database_password"

# Optional (recommended to leave defaults unless needed)
# POSTGRES_USER=sure_user
# POSTGRES_DB=sure_production

# Host port (defaults to 3333)
# PORT=3333

# Optional integrations
# TWELVE_DATA_API_KEY=
# OPENAI_ACCESS_TOKEN=

# Optional SMTP settings (for password reset, emails)
# SMTP_ADDRESS=
# SMTP_PORT=465
# SMTP_USERNAME=
# SMTP_PASSWORD=
# SMTP_TLS_ENABLED=true
# EMAIL_SENDER=no-reply@example.com

# SSL settings if behind a TLS proxy
# RAILS_FORCE_SSL=true
# RAILS_ASSUME_SSL=true

# Pin image to a specific tag/commit (optional). If unset, uses "latest".
# BUILD_COMMIT_SHA=
```

Notes:
- `POSTGRES_PASSWORD` is required; `POSTGRES_USER` and `POSTGRES_DB` default to `sure_user` and `sure_production`.
- The app listens on container port 3333; the host port defaults to 3333 and can be changed via `PORT`.
- Only variables listed above are read by the containers as defined in `docker-compose.yml`.

### Step 4: Run the app

Start the stack and check logs:

```bash
docker compose up
```

When services are healthy, open your browser to:

http://localhost:3333

You should see the Sure login screen.

### Step 5: Create your account

On first run, click "Create your account" on the login page and register with your email and password.

### Step 6: Run the app in the background

Most self-hosting users will want the Sure app to run in the background on their computer so they can access it at all times. To do this, hit `Ctrl+C` to stop the running process, and then run the following command:

```bash
docker compose up -d
```

Verify it is running:

```bash
docker compose ls
```

### Step 7: Enjoy!

Your app is now running at http://localhost:3333 (or your chosen `PORT`).

If you find bugs or have feature requests, open an issue on GitHub.

## How to update your app

The stack pulls a prebuilt image defined in the compose file:

```yml
image: ghcr.io/horovoi/sure:${BUILD_COMMIT_SHA:-latest}
```

To update to the newest published image:

```bash
cd ~/docker-apps/sure
docker compose pull
docker compose up -d web worker
```

## How to pin the app to a specific version

You can pin to a specific tag or commit by setting `BUILD_COMMIT_SHA` in your `.env` (for example a release tag or commit SHA):

```dotenv
BUILD_COMMIT_SHA=latest
# or: BUILD_COMMIT_SHA=68528a115638
```

Then redeploy:

```bash
docker compose pull
docker compose up -d web worker
```

## Troubleshooting

### ActiveRecord::DatabaseConnectionError

If this is your first start and you hit a database connection error, Docker may have initialized the database with an unexpected role from a previous attempt.

You can reset the stack (this deletes all data: database, redis, and uploaded files stored in volumes):

```bash
docker compose down -v
docker compose up
```

To verify the DB is reachable after startup:

```bash
docker compose exec db psql -U sure_user -d sure_production -c "SELECT 1;"
# If you customized POSTGRES_USER/POSTGRES_DB, substitute those values.
```
