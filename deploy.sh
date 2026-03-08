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
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/backups}"
mkdir -p "$BACKUP_DIR/pre-deploy"

# Check if database volume has data (not just if container is running)
COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.production"
PROJECT_NAME=$(${COMPOSE} config --format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "sure")
FULL_VOLUME="${PROJECT_NAME}_postgres-data"

if docker volume inspect "$FULL_VOLUME" &>/dev/null; then
  # Volume exists — ensure DB is running for backup
  echo "💾 Starting database for pre-deploy backup..."
  ${COMPOSE} up -d db
  ${COMPOSE} exec db sh -c 'until pg_isready -U ${POSTGRES_USER:-sure_user}; do sleep 1; done'

  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="$BACKUP_DIR/pre-deploy/sure_pre_deploy_${TIMESTAMP}_${COMMIT_SHA}.sql.gz"

  # Source .env.production to get DB credentials
  set -a
  source .env.production
  set +a

  ${COMPOSE} exec -T db \
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
  echo "ℹ️  No database volume found. Skipping pre-deploy backup (first deploy)."
fi

# Deploy
echo "🔄 Pulling updated images..."
${COMPOSE} pull

echo "🧱 Starting database dependencies..."
${COMPOSE} up -d db redis
${COMPOSE} exec db sh -c 'until pg_isready -U ${POSTGRES_USER:-sure_user} -d ${POSTGRES_DB:-sure_production}; do sleep 1; done'
${COMPOSE} exec redis sh -c 'until redis-cli ping | grep -q PONG; do sleep 1; done'

echo "🗄️ Running database migrations..."
${COMPOSE} run --rm web bin/rails db:migrate

echo "🚀 Starting application services..."
${COMPOSE} up -d web worker

echo "✅ Deployment complete!"
echo "🌐 Application should be available at: http://localhost:${PORT:-3333}"

# Show running containers
echo "📋 Running containers:"
${COMPOSE} ps
