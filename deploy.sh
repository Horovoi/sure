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