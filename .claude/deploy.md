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
3. Backs up the production database to `backups/pre-deploy/` (the last 10 are kept).
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
  migration, restore the pre-deploy backup.
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
  Redis on port 6380. They run on the host, which does have internet access; the
  placeholder credentials are what keeps them safe.
- `bin/staging bench` runs the old version twice and the new one once, taking turns.
  The "old-b vs old-a" column is the difference between two identical containers:
  treat any old-versus-new difference of that size as noise.

Use staging, not production, to try a risky change, to reproduce a problem that needs
real data, and to measure performance.

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

## Files

| File | Role |
|---|---|
| `bin/deploy`, `bin/staging` | The two entry points; both have `--help` |
| `script/deploy/lib.sh` | Shared shell functions (copying, migration check, images) |
| `script/staging/defuse.rb` | Replaces provider credentials in the copy |
| `script/bench/` | Benchmark containers, request driver and summary |
| `docker-compose.prod.yml` | Production services; also the base for staging |
| `docker-compose.staging.yml` | Staging differences: closed network, proxy, published ports |
| `Dockerfile`, `.dockerignore` | The image. Keep `BUILD_COMMIT_SHA` as the last instruction so dependency layers stay cached |
