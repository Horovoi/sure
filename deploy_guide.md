# Complete Guide: Push to GHCR and Deploy with Pre-built Image

## Step 1: Setup GitHub Container Registry Authentication

First, create a GitHub Personal Access Token with `write:packages` permission:

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token with `write:packages` and `read:packages` scopes
3. Save the token securely

Login to GHCR:

```bash
echo "your_github_token_here" | docker login ghcr.io -u Horovoi --password-stdin
```

## Step 2: Build and Push Image to GHCR

Set your commit SHA and build the image:

```bash
# Set the latest commit SHA
export BUILD_COMMIT_SHA="fdc989d2f652"  # Using short SHA

# Build the image with commit SHA tag
docker build \
  --build-arg BUILD_COMMIT_SHA=$BUILD_COMMIT_SHA \
  -t ghcr.io/horovoi/sure:$BUILD_COMMIT_SHA \
  -t ghcr.io/horovoi/sure:latest \
  .

# Push both tags
docker push ghcr.io/horovoi/sure:$BUILD_COMMIT_SHA
docker push ghcr.io/horovoi/sure:latest
```

## Step 3: Verify Image is Available

```bash
# Check if image exists in registry
docker manifest inspect ghcr.io/horovoi/sure:fdc989d2f652

# Or pull to test
docker pull ghcr.io/horovoi/sure:fdc989d2f652
```
## Step 4: Prepare Deployment Environment

Ensure you have a `docker-compose.prod.yml` file configured to use the image from GHCR.


## Step 5: Update Environment Configuration

Add the commit SHA to your `.env.production`:

```bash
# Build Configuration
BUILD_COMMIT_SHA=fdc989d2f652

# Database Configuration
POSTGRES_USER=sure_user
POSTGRES_PASSWORD=your_secure_password_here
POSTGRES_DB=sure_production

# Rails Configuration
SECRET_KEY_BASE=your_generated_secret_key_base_here
PORT=3000

# API Keys
TWELVE_DATA_API_KEY=your_twelve_data_api_key
OPENAI_ACCESS_TOKEN=your_openai_token

# SMTP Configuration
SMTP_ADDRESS=smtp.your-provider.com
SMTP_PORT=587
SMTP_USERNAME=your_smtp_username
SMTP_PASSWORD=your_smtp_password
SMTP_TLS_ENABLED=true
EMAIL_SENDER=noreply@yourdomain.com
```

## Step 6: Deploy with Pre-built Image

```bash
# Set the commit SHA
export BUILD_COMMIT_SHA="fdc989d2f652"

# Pull the specific image and deploy
docker compose -f docker-compose.prod.yml --env-file .env.production pull && \
docker compose -f docker-compose.prod.yml --env-file .env.production up -d
```

## Step 7: Create Automation Script

Create a deployment script for future use:

```bash
#!/bin/bash

set -e  # Exit on any error

# Get commit SHA (use argument or current commit)
COMMIT_SHA=${1:-$(git rev-parse --short=12 HEAD)}
FULL_SHA=$(git rev-parse HEAD)

echo "🚀 Deploying commit: $COMMIT_SHA (full: $FULL_SHA)"

# Build and push image
echo "📦 Building image..."
docker build \
  --build-arg BUILD_COMMIT_SHA=$FULL_SHA \
  -t ghcr.io/horovoi/sure:$COMMIT_SHA \
  -t ghcr.io/horovoi/sure:latest \
  .

echo "⬆️  Pushing to registry..."
docker push ghcr.io/horovoi/sure:$COMMIT_SHA
docker push ghcr.io/horovoi/sure:latest

# Update environment file
echo "⚙️  Updating environment..."
sed -i '' "s/BUILD_COMMIT_SHA=.*/BUILD_COMMIT_SHA=$COMMIT_SHA/" .env.production

# Set environment variable
export BUILD_COMMIT_SHA=$COMMIT_SHA

# Deploy
echo "🔄 Deploying containers..."
docker compose -f docker-compose.prod.yml --env-file .env.production pull
docker compose -f docker-compose.prod.yml --env-file .env.production up -d

echo "✅ Deployment complete!"
echo "🌐 Application should be available at: http://localhost:${PORT:-3333}"

# Show running containers
echo "📋 Running containers:"
docker compose -f docker-compose.prod.yml ps
```

Make it executable:

```bash
chmod +x deploy.sh
```

## Step 8: Usage

```bash
# Deploy current commit
./deploy.sh

# Deploy specific commit
./deploy.sh 1fe2bc352ae4

# Or manual deployment
export BUILD_COMMIT_SHA="1fe2bc352ae4"
docker compose -f docker-compose.prod.yml --env-file .env.production up -d
```

## Step 9: Verification

```bash
# Check running containers
docker compose -f docker-compose.prod.yml ps

# Check logs
docker compose -f docker-compose.prod.yml logs -f web

# Verify the deployed commit
docker compose -f docker-compose.prod.yml exec web env | grep BUILD_COMMIT_SHA
```

## Benefits of This Approach

1. **Faster deployments** - No need to rebuild locally
2. **Consistent images** - Same image across environments
3. **Version tracking** - Each deployment tagged with commit SHA
4. **Rollback capability** - Easy to deploy previous versions
5. **CI/CD ready** - Can be automated in GitHub Actions

This setup allows you to build once, deploy anywhere, and maintain full traceability of your deployments.
