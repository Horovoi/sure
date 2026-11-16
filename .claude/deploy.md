# Deploy and Staging

This app is one person's finance tracker. Production runs on this machine (an ARM Mac)
in Docker. There is no registry, no CI and no second architecture: deploying means
building the current commit here and starting it.

## Layout

| | Production | Staging |
|---|---|---|
| Purpose | The real app and data | A private copy of production for testing |
| Compose project | `sure` | `sure-staging` |
| URL | http://localhost:3333 | http://localhost:3334 |
| Compose files | `docker-compose.prod.yml` | the same, plus `docker-compose.staging.yml` |
| Data volumes | `sure_postgres-data`, `sure_app-storage`, `sure_icons`, `sure_redis-data` | `sure-staging_*` |
| Started by | `bin/deploy` | `bin/staging` |

Both read `.env.production`. Images are built locally and tagged `sure:<12-character commit>`.
`.env.production` records the deployed tag in `BUILD_COMMIT_SHA`.

## Deploying

Deploy only when the user asks. Commit first, then run from the repository root:

```bash
bin/deploy                    # build, rehearse on a copy of production, back up, migrate, start
bin/deploy --skip-rehearsal   # the same without the rehearsal
bin/deploy --rollback <ref>   # switch back to an image built by an earlier deploy
bin/deploy --allow-row-loss   # continue when a migration removes rows on purpose
```

A normal deploy takes about half a minute. What it does, in order:

1. Builds `sure:<commit>` from the working tree. Uncommitted changes are included and listed.
2. Rehearsal: copies production into staging, runs the new migrations there, checks that
   no table lost rows and that the app starts. If this fails, production is untouched.
3. Writes a pre-deploy backup bundle to `backups/bundles/pre-deploy/` and mirrors it
   off-site (the last 10 are kept in each place). See [Backups](#backups).
4. If migrations are pending: stops the app, migrates, checks again that no table lost rows.
5. Starts web, worker and the scheduled backup container, and waits for the health check.

After a deploy, report the tag it printed. To look further:

```bash
docker compose -p sure -f docker-compose.prod.yml --env-file .env.production ps
docker compose -p sure -f docker-compose.prod.yml --env-file .env.production logs --tail 100 web
```

### Migrations

- `bin/deploy` is the only thing that runs migrations in production. The container
  entrypoint does not, so restarting a container never changes the schema.
- A rollback switches the image only. It does not undo migrations. To go back past a
  migration, restore the pre-deploy bundle (the owner does this, see
  [Restoring production](#restoring-production-the-owner-only)).
- Write migrations so the previous version still works on the new schema where possible;
  that keeps `--rollback` useful.

## Staging: testing against real data

```bash
bin/staging refresh             # replace the copy with fresh production data
bin/staging up [<ref>]          # run a version on the copy (default: the deployed one)
bin/staging up --build          # build the working tree and run that
bin/staging up ... --worker     # also run background jobs
bin/staging down [--wipe]       # stop staging (--wipe also deletes the copy)
bin/staging dev                 # bin/dev with hot reload on the copy (port 3000)
bin/staging run <command...>    # any command against the copy, e.g. bin/rails console
bin/staging exec <command...>   # a command in the running staging worker container
bin/staging restore <bundle>    # load a backup bundle into the copy and start it
bin/staging bench <old> <new>   # compare page speed of two versions on the copy
```

- The copy is physical (`pg_basebackup`), so statistics, indexes and query plans match
  production. Uploaded files and cached icons are copied too.
- Provider credentials in the copy are replaced with placeholders, and the staging
  app containers have no internet access. Nothing run in staging can reach a bank,
  a market data provider or a mail server.
- Background jobs are off unless `--worker` is given, so the copied data stays as it
  was. Leave them off for benchmarks.
- `bin/staging dev` and `bin/staging run` use the staging database on port 5433 and
  Redis on port 6380. They copy the copy's cached logos into `public/icons` and pass
  production's Brandfetch settings, so logos look as they do in production. They run on the host, which does have internet access; the
  placeholder credentials are what keeps them safe. `bin/staging dev` stops the
  staging worker container if it runs, so bin/dev's own worker runs every job.
- `bin/staging bench` runs the old version twice and the new one once, taking turns.
  The "old-b vs old-a" column is the difference between two identical containers:
  treat any old-versus-new difference of that size as noise.

Use staging, not production, to try a risky change, to reproduce a problem that needs
real data, and to measure performance.

## Backups

Two kinds of backup live in `BACKUP_DIR` (default `./backups`):

- The **daily database sidecar** (the `backup` service, `prodrigestivill/postgres-backup-local`)
  writes database dumps to `backups/daily`, `weekly`, `monthly` and `last`, and prunes them
  itself. Nothing else writes or deletes there.
- **Bundles** (`Backup::Bundle`): a full, restorable copy in one folder under
  `backups/bundles/<kind>/<UTC stamp>_<tag>/`:

  | File | What |
  |---|---|
  | `db.sql.gz` | Plain SQL dump of the database (`gunzip -c db.sql.gz \| psql`) |
  | `storage.tar.gz` | The `app-storage` volume (`/rails/storage`, uploaded files) |
  | `icons.tar.gz` | The `icons` volume (`/rails/public/icons`) |
  | `env.production.age` | `.env.production`, encrypted with age to `BACKUP_AGE_RECIPIENT` (mode 600). Skipped, and `"env": "skipped"` in the manifest, when no recipient is set |
  | `manifest.json` | Kind, tag, build commit, time, schema version, pg_dump version, the row count of every table, and size plus sha256 of every file |

| Kind | Made by | Parts | Kept here / off-site |
|---|---|---|---|
| `daily` | `FullBackupJob`, 04:00 Kyiv (`config/schedule.yml`, `full_backup`) | all | 7 / 30 |
| `pre-deploy` | `bin/deploy` step 3 | all | 10 / 10 |
| `pre-reset` | `FamilyResetJob`, before it deletes anything | database and files | 5 / 5 |
| `manual` | `bin/rails 'backup:create[manual]'` | all | 5 / 5 |

- Every bundle is copied to `OFFSITE_BACKUP_DIR/bundles/<kind>/` (`/offsite` in the worker)
  and each file is checked against its sha256 there. Without `OFFSITE_BACKUP_DIR` the
  mirror is `backups/offsite`, on the same disk; `bin/deploy` warns about that.
- Pruning deletes only folders named `<stamp>_<tag>` that hold a `manifest.json`. Other
  files and folders, and the flat `backups/pre-deploy/sure_pre_deploy_*.sql.gz` files from
  before bundles, are left alone.
- The pre-deploy bundle: `bin/deploy` dumps the database through the db container and
  tars both volumes read-only (no Rails), then runs `bin/rails 'backup:seal[<dir>,pre_deploy]'`
  in a one-off worker of the new image, which adds the encrypted env file and the
  manifest, mirrors and prunes. If sealing fails the deploy stops before touching
  production, and the dump and tarballs stay in the folder it names. Its env copy holds
  the new `BUILD_COMMIT_SHA`, so it differs from `.env.production` in that one line.
- The worker mounts `BACKUP_DIR` at `/backups`, `OFFSITE_BACKUP_DIR` at `/offsite` and
  `.env.production` read-only at `/run/secrets/env.production`. `bin/deploy` rewrites
  `.env.production` in place (`cat >`) so that single-file mount keeps working.
- On staging the worker mounts `backups/staging` instead, so bundles made on the copy
  (manual, or pre-reset from a reset there) land only in `backups/staging/bundles/`. The
  daily job does nothing on staging.

### Owner one-time setup

1. `brew install age`, then `age-keygen -o sure-backup.key`. Put the private key (the
   whole file) in the password manager and delete the file. Never store it in this
   repository, in `backups/` or in the off-site folder.
2. Add to `.env.production`: `BACKUP_AGE_RECIPIENT=age1...` (the public key that
   `age-keygen` printed) and `OFFSITE_BACKUP_DIR=/path/to/another/disk/sure-backups`.
3. Deploy (`bin/deploy`); it recreates the worker with the new mounts. Check that the
   pre-deploy bundle is in both `backups/bundles/pre-deploy/` and the off-site folder.

### Testing a bundle on staging

```bash
bin/staging up --worker
bin/staging exec bin/rails 'backup:create[manual]'   # writes backups/staging/bundles/manual/...
bin/staging restore backups/bundles/daily/<name>     # or any bundle folder
```

`bin/staging restore` checks every sha256 against the manifest, stops the staging app,
drops and recreates the staging database, loads `db.sql.gz`, unpacks the tarballs into
the staging volumes, defuses provider credentials, prints any table whose row count
differs from the manifest, then migrates and starts the deployed version on it. It never
decrypts `env.production.age`: the private key stays with the owner.

### Restoring production (the owner only)

Claude never restores production. The owner runs these by hand, from the repository
root, with the bundle folder in `B`:

```bash
B=backups/bundles/pre-deploy/<name>
shasum -a 256 "$B"/*.gz "$B"/*.age          # compare with manifest.json
# 1. The env file, if it was lost or changed (key from the password manager):
age -d -i /path/to/sure-backup.key "$B/env.production.age" > .env.production.restored
# 2. Stop the app and load the dump into a fresh database:
P="docker compose -p sure -f docker-compose.prod.yml --env-file .env.production"
$P stop web worker
$P exec -T db sh -c 'dropdb -U "$POSTGRES_USER" --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
gunzip -c "$B/db.sql.gz" | sed '/^SET transaction_timeout = /d' |
  $P exec -T db sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
# 3. Unpack the volumes:
$P run --rm --no-deps -v "$PWD/$B:/bundle:ro" --entrypoint sh web -c \
  'find /rails/storage -mindepth 1 -delete && tar -xzf /bundle/storage.tar.gz -C /rails/storage'
$P run --rm --no-deps -v "$PWD/$B:/bundle:ro" --entrypoint sh web -c \
  'find /rails/public/icons -mindepth 1 -delete && tar -xzf /bundle/icons.tar.gz -C /rails/public/icons'
# 4. Start the version that matches the restored schema (see below):
bin/deploy --rollback <commit>
```

The `sed` line drops a setting that pg_dump 17 writes and the postgres 16 server does
not know. For a daily, manual or pre-reset bundle, the matching version is the tag in
its folder name. A pre-deploy bundle holds the database as it was before that deploy's
migrations, while its tag names the new version: start the version deployed before it.

## Rules

- Never delete or recreate the `sure_*` volumes, and never run `docker compose down -v`
  (or `--volumes`) on the `sure` project. That is the user's financial data.
- Never run migrations, consoles or scripts against production by hand. Use
  `bin/staging run` on the copy. If production itself must change, ask first.
- Never push an image to a registry. An earlier setup published images that contained
  database backups.
- Never point `bin/rails test` or any development command at production or staging
  databases, and do not load `.env.production` into other commands. Tests wipe the
  database they run against.
- Keep private files out of the image: anything new at the repository root that is not
  needed at runtime belongs in `.dockerignore`.
- Do not start, stop or remove production containers except through `bin/deploy`.

## Background job lanes

The worker runs Sidekiq with two lanes (capsules), set in `config/sidekiq.yml`:

| Lane | Threads | Queues |
|---|---|---|
| default | `RAILS_MAX_THREADS` minus `RAILS_AI_MAX_THREADS` (at least 1) | `scheduled`, `high_priority`, `medium_priority`, `low_priority`, `default` (weighted) |
| ai | `RAILS_AI_MAX_THREADS` | `ai_high_priority` (chat turns), then `ai_low_priority` (auto-categorize, merchant detection, PDF processing), in strict order |

An AI job holds its thread for the whole model call, and a Claude turn can take minutes, so AI jobs
have their own lane and cannot hold up syncs, imports and rule runs.

- `docker-compose.prod.yml` sets the worker to `RAILS_MAX_THREADS=5` and `RAILS_AI_MAX_THREADS=2`
  (3 default threads, 2 AI threads). Staging inherits this. Puma (the web service) does not set
  them and keeps its default of 3.
- `config/database.yml` sizes the pool from `RAILS_MAX_THREADS`, so the two lanes together never
  need more connections than the pool holds. Change both variables together.
- Without the variables (development) the worker runs 3 threads: 2 default, 1 AI.
- After the first deploy with lanes, jobs already queued under the old queue names
  (`high_priority` for chat, `medium_priority` for the others) run one more time in the default lane.
- A chat turn waiting in the AI queue counts as lost after 30 minutes without progress, a running
  one after 10 minutes (`AssistantMessage::PENDING_STALE_AFTER` and `STALE_AFTER`).

## Claude bridge

Claude in Sure's chat runs through a small Node server on this Mac, `claude_bridge/server.ts`.
It drives Claude Code through the Agent SDK with the owner's own `claude auth login` (no API
key). Sure, in Docker, calls it at `http://host.docker.internal:3339`.

```bash
bin/claude-bridge install [--write-env]   # LaunchAgent + `claude mcp add --scope user sure`
bin/claude-bridge status                  # Node, bundled Claude Code, agent, login, usage, token
bin/claude-bridge logs                    # follow ~/Library/Logs/sure-claude-bridge.log
bin/claude-bridge restart
bin/claude-bridge uninstall               # unload, `claude mcp remove`, files to the Trash
bin/claude-bridge run                     # foreground, for bin/dev or bin/staging dev
```

- **Install** runs `npm ci` in `claude_bridge/`, then writes
  `~/Library/LaunchAgents/ua.sure.claude-bridge.plist` (the absolute Node path, RunAtLoad,
  KeepAlive), `~/.config/sure-claude-bridge/config.json` (port, token and the MCP URL
  allowlist, mode 600) and the log file, and loads the agent with `launchctl bootstrap`.
  It also registers production's `/mcp` with Claude Code (`claude mcp add --scope user
  --transport http sure http://localhost:3333/mcp`, header from `MCP_API_TOKEN` in
  `.env.production`; the token is never printed).
- **The token.** `CLAUDE_BRIDGE_TOKEN` must be the same in `config.json` and
  `.env.production`. Install takes it from `.env.production` if it is there, else from an
  earlier install, else makes a new one. It does not edit `.env.production` on its own:
  it asks (or takes `--write-env`) and otherwise prints the `CLAUDE_BRIDGE_URL` and
  `CLAUDE_BRIDGE_TOKEN` lines to add. `docker-compose.prod.yml` passes both to web and
  worker; they take effect at the next `bin/deploy`. Without them the Claude chat is off.
- **Re-run install after a Node upgrade.** The plist records the absolute Node path (nvm),
  and `status` reports when it is gone.
- **Network.** It listens on `127.0.0.1:3339` only, drops connections from anything but
  loopback, and checks the token on every request. Nothing on the LAN can reach it, unlike
  the app on `0.0.0.0:3333`. Each turn's `mcp.url` must be one of Sure's local `/mcp`
  endpoints (ports 3333, 3000, 3334).
- **What a turn may do.** No built-in tools (no shell, files or web); only Sure's MCP tools,
  all of them, with no approval prompt, through a per-turn token sent over stdin. Claude
  Code ignores the owner's settings, hooks, plugins and other MCP servers for these turns.
  At most 2 turns at a time (a third gets "busy"), 16 tool rounds, 8 minutes.
  A turn stops when Sure disconnects or when a usage window is used up.
- **Version pin.** `@anthropic-ai/claude-agent-sdk` is pinned exactly. The Claude Code it
  bundles must be at least `sure.minClaudeCodeVersion` in `claude_bridge/package.json`
  (the first version that speaks MCP 2026-07-28 with Sure); the bridge refuses to start
  otherwise. To upgrade: change the pin, `npm install` in `claude_bridge/`, run
  `node --test 'claude_bridge/*.test.ts'`, then `bin/claude-bridge install`.
- **Logs** hold ids, error codes and timings, never prompts, answers or tokens.
- **Staging** containers cannot reach the bridge (their network is closed). To try Claude
  against the copy, run `bin/staging dev` and `bin/claude-bridge run` (or the agent).
- Turns are saved as Claude Code sessions under `~/.claude/projects/` for the folder
  `~/Library/Application Support/sure-claude-bridge/work`; each turn forks the last one.
- **Sure's side** (`Assistant::Claude`). A turn whose model is a Claude model (`opus`, `sonnet`,
  `haiku` or a `claude-*` id) goes to the bridge; anything else stays on OpenAI. Settings > AI
  shows the account, plan, the 5-hour and 7-day windows (reset times in the family time zone) and
  the chat model select (blank = `sonnet` when the bridge is configured). Each turn sends
  `CLAUDE_BRIDGE_MCP_URL` (default `http://localhost:$PORT/mcp`) and a 15-minute turn token that
  `/mcp` accepts only while that message streams and only with the user's AI switch on (the
  Self-Hosting MCP switch does not apply to it). Usage goes to LLM Usage as
  `claude_subscription` rows at API-equivalent cost; every tool call to AI tool calls as
  `claude_chat`.

## Files

| File | Role |
|---|---|
| `bin/deploy`, `bin/staging` | The two entry points; both have `--help` |
| `script/deploy/lib.sh` | Shared shell functions (copying, migration check, images) |
| `script/staging/defuse.rb` | Replaces provider credentials in the copy |
| `script/staging/bundle_check.rb` | Checks a bundle against its manifest for `bin/staging restore` |
| `app/models/backup/bundle.rb`, `lib/tasks/backup.rake`, `app/jobs/full_backup_job.rb` | Backup bundles |
| `script/bench/` | Benchmark containers, request driver and summary |
| `docker-compose.prod.yml` | Production services; also the base for staging |
| `docker-compose.staging.yml` | Staging differences: closed network, proxy, published ports |
| `Dockerfile`, `.dockerignore` | The image. Keep `BUILD_COMMIT_SHA` as the last instruction so dependency layers stay cached |

## MCP endpoint (Claude Code)

`/mcp` is off until two lines are in `.env.production`. The owner sets the values; do not write
them into the file for him:

```bash
MCP_API_TOKEN=...        # generate with: openssl rand -hex 32
MCP_USER_EMAIL=...       # the Sure login the tools run as (an active user of the family)
```

Then `bin/deploy` (or restart through it) so the containers read them. Without a token the endpoint
answers 503; with a token but no active user for the email, also 503. Staging reads the same file,
so the same token works against http://localhost:3334/mcp.

Settings > Self-Hosting > MCP Server shows whether both are set and has an "Allow MCP clients" switch
(`Setting.mcp_enabled`, on by default). Turning it off makes `/mcp` answer 403 to the static token at
once, without a deploy. The in-app chat's Claude does not use this token and is not affected; the
user's AI switch gates it. To revoke the token itself, change `MCP_API_TOKEN` and deploy.
