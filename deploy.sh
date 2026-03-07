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

# Pre-deploy database backup
BACKUP_DIR="${BACKUP_DIR:-$HOME/sure-backups}"
mkdir -p "$BACKUP_DIR/pre-deploy"

DB_CONTAINER=$(docker compose -f docker-compose.prod.yml --env-file .env.production ps -q db 2>/dev/null)
if [ -n "$DB_CONTAINER" ] && docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="$BACKUP_DIR/pre-deploy/sure_pre_deploy_${TIMESTAMP}_${COMMIT_SHA}.sql.gz"
  echo "💾 Creating pre-deploy backup..."

  # Source .env.production to get DB credentials
  set -a
  source .env.production
  set +a

  docker compose -f docker-compose.prod.yml --env-file .env.production exec -T db \
    pg_dump -U "${POSTGRES_USER:-sure_user}" "${POSTGRES_DB:-sure_production}" | gzip > "$BACKUP_FILE"

  if [ $? -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
    echo "✅ Pre-deploy backup saved: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
  else
    echo "⚠️  Pre-deploy backup failed! Aborting deploy."
    echo "   Run with SKIP_BACKUP=1 to deploy without backup."
    [ "${SKIP_BACKUP}" != "1" ] && exit 1
  fi

  # Clean up old pre-deploy backups (keep last 10)
  ls -tp "$BACKUP_DIR/pre-deploy"/sure_pre_deploy_*.sql.gz 2>/dev/null | tail -n +11 | xargs rm -- 2>/dev/null || true
else
  echo "⚠️  No running database container found. Skipping pre-deploy backup."
  echo "   This is expected on first deploy."
fi

# Deploy
echo "🔄 Deploying containers..."
docker compose -f docker-compose.prod.yml --env-file .env.production pull
docker compose -f docker-compose.prod.yml --env-file .env.production up -d

echo "✅ Deployment complete!"
echo "🌐 Application should be available at: http://localhost:${PORT:-3333}"

# Show running containers
echo "📋 Running containers:"
docker compose -f docker-compose.prod.yml ps