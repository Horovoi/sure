# Shared by bin/deploy and bin/staging. Sourced, not run.
#
# Two stacks run from the same compose file on this machine:
#   prod     project "sure"          the real app and its data
#   staging  project "sure-staging"  a private copy, on a network with no internet access

ENV_FILE=.env.production
STAGING_PORT="${STAGING_PORT:-3334}"
STAGING_DB_PORT="${STAGING_DB_PORT:-5433}"
STAGING_REDIS_PORT="${STAGING_REDIS_PORT:-6380}"

die() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "▸ $*"; }

# Runs a command silently; shows its output only if it fails
quiet() {
  local out
  out=$("$@" 2>&1) || { echo "$out" >&2; return 1; }
}

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found (run from the repository root)"

# Value of a key in the env file, without surrounding quotes
env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# The image tag production runs, as recorded by the last deploy
deployed_tag() { env_value BUILD_COMMIT_SHA; }

# TAG selects which image a stack runs. Callers set it before using these.
prod() {
  BUILD_COMMIT_SHA="$TAG" docker compose --progress quiet -p sure -f docker-compose.prod.yml --env-file "$ENV_FILE" "$@"
}

staging() {
  BUILD_COMMIT_SHA="$TAG" docker compose --progress quiet -p sure-staging \
    -f docker-compose.prod.yml -f docker-compose.staging.yml -f script/bench/compose.yml \
    --env-file "$ENV_FILE" "$@"
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

# Image tag for a git ref: its short commit id
tag_for() { git rev-parse --short=12 "$1^{commit}" 2>/dev/null || die "not a commit: $1"; }

image_exists() { docker image inspect "sure:$1" >/dev/null 2>&1; }

# Builds sure:<tag> for a commit from a clean checkout, leaving the working tree alone
build_commit() {
  local tag="$1" dir="tmp/build-$1" status=0
  echo "  building sure:$tag from a clean checkout"
  quiet git worktree add --detach "$dir" "$tag"
  quiet docker build -t "sure:$tag" --build-arg BUILD_COMMIT_SHA="$(git rev-parse "$tag")" "$dir" || status=$?
  quiet git worktree remove --force "$dir"
  return $status
}

# Prints the tag for a ref, building its image first if there is none yet
ensure_image() {
  local tag
  tag=$(tag_for "$1")
  image_exists "$tag" || build_commit "$tag" >&2
  echo "$tag"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

# Runs SQL from stdin in a stack's database: `sql prod` or `sql staging`
sql() {
  "$1" exec -T db sh -c 'psql -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

# Exact row count of every table, one "table|count" line each
table_counts() {
  sql "$1" <<'SQL'
select table_name || '|' ||
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE'
order by table_name;
SQL
}

# Compares two table_counts outputs. Fails, listing the tables, if any table
# lost rows or disappeared.
check_no_rows_lost() {
  awk -F'|' '
    NR == FNR { before[$1] = $2; next }
    { after[$1] = $2 }
    END {
      for (t in before) {
        if (!(t in after)) { print "  " t ": table is gone (had " before[t] " rows)"; bad = 1 }
        else if (after[t] + 0 < before[t] + 0) { print "  " t ": " before[t] " rows before, " after[t] " after"; bad = 1 }
      }
      exit bad
    }' "$1" "$2"
}

# Migration versions that an image has and a stack's database does not
pending_migrations() {
  local have want
  have=$(echo "select version from schema_migrations" | sql "$1" | sort)
  want=$(docker run --rm --entrypoint sh "sure:$2" -c 'ls db/migrate' | sed -n 's/^\([0-9]\{14\}\)_.*/\1/p' | sort)
  comm -13 <(echo "$have") <(echo "$want")
}

# Runs pending migrations in a stack and checks that no table lost rows.
# Returns 1 if rows were lost. Does nothing when there is nothing to migrate.
migrate_checked() {
  local stack="$1" pending before after
  pending=$(pending_migrations "$stack" "$TAG")
  if [ -z "$pending" ]; then
    echo "  no pending migrations"
    return 0
  fi

  echo "  $(echo "$pending" | wc -l | tr -d ' ') pending migration(s): $(echo "$pending" | tr '\n' ' ')"
  before=$(mktemp) after=$(mktemp)
  table_counts "$stack" > "$before"
  "$stack" run --rm web bin/rails db:migrate
  table_counts "$stack" > "$after"

  if check_no_rows_lost "$before" "$after"; then
    echo "  migrated; no table lost rows ($(wc -l < "$after" | tr -d ' ') tables checked)"
  else
    echo "  ✗ the tables above lost rows during migration" >&2
    return 1
  fi
}

# Waits until a URL answers with a success status
wait_for_http() {
  local i
  for i in $(seq 1 60); do
    curl -fs -o /dev/null "$1" && return 0
    sleep 1
  done
  die "$1 did not answer within 60 seconds"
}

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

staging_has_data() {
  [ "$(echo "select to_regclass('public.users') is not null" | sql staging 2>/dev/null)" = "t" ]
}

stop_staging_app() {
  quiet staging --profile worker --profile bench rm -sf web worker proxy web-old-a web-old-b web-new driver
}

# Copies the files of a production volume into the same volume of staging
copy_volume() {
  docker volume inspect "sure_$1" >/dev/null 2>&1 || return 0
  quiet staging run --rm --no-deps -v "sure_$1:/from:ro" --entrypoint sh web -c \
    "find $2 -mindepth 1 -delete; cp -a /from/. $2/"
}

# Replaces the staging data with a fresh copy of production: database and uploaded files.
#
# The database is copied physically (pg_basebackup), not dumped and restored, so the
# copy is exact: same statistics, same indexes, same bloat. Query plans and timings on
# the copy match production. Production keeps running while it is copied.
refresh_staging() {
  step "Copying production data into staging"
  quiet prod up -d --wait db
  stop_staging_app
  quiet staging rm -sf db
  prod exec -T db sh -c 'pg_basebackup -U "$POSTGRES_USER" -D - -Ft -X fetch --checkpoint=fast' |
    staging run --rm --no-deps -T --entrypoint sh db -c \
      'find "$PGDATA" -mindepth 1 -delete && tar -x -C "$PGDATA" -f - && chmod 700 "$PGDATA"'
  quiet staging up -d --wait db redis
  echo "  database copied ($(echo "select pg_size_pretty(pg_database_size(current_database()))" | sql staging))"

  copy_volume app-storage /rails/storage
  copy_volume icons /rails/public/icons
  echo "  uploaded files and cached icons copied"

  # The copy must never be able to act on a real bank or exchange account
  staging run --rm --no-deps -v "$PWD/script/staging:/staging:ro" web bin/rails runner /staging/defuse.rb | tail -1 | sed 's/^/  /'
}

# Starts the selected image on the staging data and checks that it serves pages
start_staging() {
  quiet staging "$@" up -d --wait web proxy
  wait_for_http "http://localhost:$STAGING_PORT/up"
  wait_for_http "http://localhost:$STAGING_PORT/sessions/new"
}
